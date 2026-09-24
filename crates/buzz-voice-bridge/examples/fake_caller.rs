//! Lab tool: play the caller's side of a huddle's audio room.
//!
//! Joins `/huddle/{channel}/audio` with the caller's key, streams a tone as
//! 48 kHz Opus for `--talk-secs`, then listens for `--listen-secs` and reports
//! what the other peers sent, as one JSON line on stdout. Never used in
//! production; see `scripts/aitaco/voice-bridge/lab.sh`.

use anyhow::Result;
use buzz_voice_bridge::{relay_io, room, wire};
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::time::{Duration, Instant};
use tokio_tungstenite::tungstenite::Message;

fn arg(name: &str) -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1).cloned())
}

#[tokio::main]
async fn main() -> Result<()> {
    let relay = arg("--relay").expect("--relay");
    let keys = relay_io::load_key_file(arg("--key-file").expect("--key-file").as_ref())?;
    let channel: uuid::Uuid = arg("--channel").expect("--channel").parse()?;
    let parent: uuid::Uuid = arg("--parent").expect("--parent").parse()?;
    // `--pcm <file>`: speak raw s16le 48 kHz mono audio instead of a tone.
    let speech: Option<Vec<i16>> = match arg("--pcm") {
        Some(path) => Some(
            std::fs::read(path)?
                .chunks_exact(2)
                .map(|b| i16::from_le_bytes([b[0], b[1]]))
                .collect(),
        ),
        None => None,
    };
    let talk_after =
        Duration::from_secs_f64(arg("--talk-after-secs").unwrap_or("0".into()).parse()?);
    let talk = match &speech {
        Some(samples) => Duration::from_secs_f64(samples.len() as f64 / 48_000.0),
        None => Duration::from_secs_f64(arg("--talk-secs").unwrap_or("2".into()).parse()?),
    };
    let listen = Duration::from_secs_f64(arg("--listen-secs").unwrap_or("8".into()).parse()?);
    // `--save-received <file>`: keep what the other peers said, s16le 48 kHz.
    let mut saved: Option<std::fs::File> = arg("--save-received")
        .map(std::fs::File::create)
        .transpose()?;

    // `--guidelines`: post Desktop's kind:48106 voice guidelines into the
    // huddle's own channel, as Desktop does before it announces, and exit. A
    // huddle carrying them is Desktop-voiced, and the bridge must stay out.
    if std::env::args().any(|a| a == "--guidelines") {
        let event = nostr::EventBuilder::new(
            nostr::Kind::Custom(48106),
            "You are in a live voice huddle.",
        )
        .tag(nostr::Tag::parse(["h", channel.to_string().as_str()])?)
        .sign_with_keys(&keys)?;
        let posted = relay_io::Publisher::new(&relay, keys.clone())?
            .publish_event(event)
            .await?;
        println!(
            "{}",
            serde_json::json!({ "guidelines": posted.id.to_hex() })
        );
        return Ok(());
    }

    // `--announce 48100|48103`: post the caller's huddle lifecycle event in
    // the parent, as the phone does, and exit.
    if let Some(kind) = arg("--announce") {
        let event = nostr::EventBuilder::new(
            nostr::Kind::Custom(kind.parse()?),
            serde_json::json!({ "ephemeral_channel_id": channel.to_string() }).to_string(),
        )
        .tag(nostr::Tag::parse(["h", parent.to_string().as_str()])?)
        .sign_with_keys(&keys)?;
        let posted = relay_io::Publisher::new(&relay, keys.clone())?
            .publish_event(event)
            .await?;
        println!(
            "{}",
            serde_json::json!({ "announced": kind, "event_id": posted.id.to_hex() })
        );
        return Ok(());
    }

    let mut joined = room::join(&relay, channel, parent, &keys).await?;
    let mut encoder = opus::Encoder::new(48_000, opus::Channels::Mono, opus::Application::Voip)?;
    let mut decoders: HashMap<u8, opus::Decoder> = HashMap::new();
    let mut encoded = vec![0u8; 4000];
    let mut pcm = vec![0i16; 5760];
    let mut received: HashMap<String, (u64, f64)> = HashMap::new();
    let mut tick = tokio::time::interval(Duration::from_millis(20));
    let start = Instant::now();
    let (mut seq, mut ts, mut phase) = (0u16, 0u32, 0f64);
    let mut sent = 0u64;
    let mut cursor = 0usize;
    while start.elapsed() < talk_after + talk + listen {
        tokio::select! {
            _ = tick.tick() => {
                let elapsed = start.elapsed();
                if elapsed >= talk_after && elapsed < talk_after + talk {
                    let frame: Vec<i16> = match &speech {
                        Some(samples) => {
                            let mut frame: Vec<i16> = samples.iter().skip(cursor).take(960).copied().collect();
                            frame.resize(960, 0);
                            cursor += 960;
                            frame
                        }
                        None => (0..960).map(|_| {
                            phase += 2.0 * std::f64::consts::PI * 300.0 / 48_000.0;
                            (phase.sin() * 8000.0) as i16
                        }).collect(),
                    };
                    let len = encoder.encode(&frame, &mut encoded)?;
                    let header = wire::FrameHeader { seq, ts_48k: ts, level_dbov: wire::level_dbov(&frame), flags: 0 };
                    joined.ws.send(Message::Binary(wire::client_frame(header, &encoded[..len]).into())).await?;
                    seq = seq.wrapping_add(1);
                    ts = ts.wrapping_add(wire::TS_PER_FRAME);
                    sent += 1;
                }
            }
            message = joined.ws.next() => match message {
                Some(Ok(Message::Binary(bytes))) => {
                    if let Some((index, _, opus_payload)) = wire::parse_relay_frame(&bytes) {
                        let who = joined.peers.get(&index).cloned().unwrap_or_else(|| format!("peer{index}"));
                        let decoder = decoders.entry(index).or_insert_with(|| opus::Decoder::new(48_000, opus::Channels::Mono).expect("decoder"));
                        let n = decoder.decode(opus_payload, &mut pcm, false).unwrap_or(0);
                        if let Some(file) = saved.as_mut() {
                            use std::io::Write;
                            for sample in &pcm[..n] {
                                file.write_all(&sample.to_le_bytes())?;
                            }
                        }
                        let entry = received.entry(who).or_insert((0, -127.0));
                        entry.0 += 1;
                        entry.1 = entry.1.max(f64::from(wire::level_dbov(&pcm[..n])));
                    }
                }
                Some(Ok(Message::Text(text))) => {
                    let value: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
                    match room::parse_control(&value) {
                        room::RoomEvent::Joined { peer_index, pubkey } => { joined.peers.insert(peer_index, pubkey); }
                        room::RoomEvent::Left { peer_index, .. } => { joined.peers.remove(&peer_index); }
                        _ => {}
                    }
                }
                Some(Ok(Message::Ping(data))) => { joined.ws.send(Message::Pong(data)).await.ok(); }
                Some(Ok(_)) => {}
                Some(Err(_)) | None => break,
            }
        }
    }
    let _ = joined.ws.send(Message::Close(None)).await;
    let report: serde_json::Value = serde_json::json!({
        "sent_frames": sent,
        "received": received.iter().map(|(who, (frames, peak))| serde_json::json!({"pubkey": who, "frames": frames, "peak_dbov": peak})).collect::<Vec<_>>(),
    });
    println!("{report}");
    Ok(())
}
