//! Huddle audio wire format, protocol v2.
//!
//! Mirrors `desktop/src-tauri/src/huddle/wire.rs` (the client half) and
//! `crates/buzz-relay/src/audio/wire.rs` (the relay's parse half):
//!
//! ```text
//! client → relay: <header: [u8; 8]><opus>
//! relay → client: <peer_index: u8><header: [u8; 8]><opus>
//!
//! header, network byte order:
//!  0..=1  seq         u16  +1 per packet, wrapping
//!  2..=5  ts_48k      u32  48 kHz media clock, +960 per 20 ms frame
//!  6      level_dbov  i8   [-127, 0], telemetry only
//!  7      flags       u8   bit 0 = DTX
//! ```

/// The wire version sent in the audio auth message.
pub const PROTOCOL_VERSION: u8 = 2;
/// Fixed v2 header length.
pub const HEADER_LEN: usize = 8;
/// Flag bit for a DTX / comfort-noise packet.
pub const FLAG_DTX: u8 = 0x01;
/// 48 kHz media-clock ticks per 20 ms frame, whatever rate the codec runs at.
pub const TS_PER_FRAME: u32 = 960;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHeader {
    pub seq: u16,
    pub ts_48k: u32,
    pub level_dbov: i8,
    pub flags: u8,
}

impl FrameHeader {
    pub fn encode(self) -> [u8; HEADER_LEN] {
        let mut out = [0u8; HEADER_LEN];
        out[0..2].copy_from_slice(&self.seq.to_be_bytes());
        out[2..6].copy_from_slice(&self.ts_48k.to_be_bytes());
        out[6] = self.level_dbov.clamp(-127, 0) as u8;
        out[7] = self.flags;
        out
    }

    pub fn parse(bytes: &[u8]) -> Option<(Self, &[u8])> {
        if bytes.len() < HEADER_LEN {
            return None;
        }
        let raw_level = bytes[6] as i8;
        Some((
            Self {
                seq: u16::from_be_bytes([bytes[0], bytes[1]]),
                ts_48k: u32::from_be_bytes([bytes[2], bytes[3], bytes[4], bytes[5]]),
                level_dbov: if (-127..=0).contains(&raw_level) {
                    raw_level
                } else {
                    -127
                },
                flags: bytes[7],
            },
            &bytes[HEADER_LEN..],
        ))
    }
}

/// Split a relay-to-client frame into sender peer index, header and Opus
/// payload. A frame with no payload is malformed.
pub fn parse_relay_frame(bytes: &[u8]) -> Option<(u8, FrameHeader, &[u8])> {
    let (&peer_index, rest) = bytes.split_first()?;
    let (header, opus) = FrameHeader::parse(rest)?;
    if opus.is_empty() {
        return None;
    }
    Some((peer_index, header, opus))
}

/// Build a client-to-relay frame.
pub fn client_frame(header: FrameHeader, opus: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_LEN + opus.len());
    out.extend_from_slice(&header.encode());
    out.extend_from_slice(opus);
    out
}

/// RMS level of a 16-bit PCM frame in dBov, clamped to [-127, 0].
pub fn level_dbov(samples: &[i16]) -> i8 {
    if samples.is_empty() {
        return -127;
    }
    let sum: f64 = samples
        .iter()
        .map(|&s| {
            let x = f64::from(s) / 32768.0;
            x * x
        })
        .sum();
    let rms = (sum / samples.len() as f64).sqrt();
    if rms <= 0.0 {
        return -127;
    }
    (20.0 * rms.log10()).round().clamp(-127.0, 0.0) as i8
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_round_trips_in_network_byte_order() {
        let header = FrameHeader {
            seq: 0x0102,
            ts_48k: 0x0304_0506,
            level_dbov: -1,
            flags: FLAG_DTX,
        };
        let bytes = header.encode();
        assert_eq!(bytes, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0xFF, 0x01]);
        let (parsed, rest) = FrameHeader::parse(&bytes).expect("parse");
        assert_eq!(parsed, header);
        assert!(rest.is_empty());
    }

    #[test]
    fn relay_frame_has_one_peer_byte_and_needs_a_payload() {
        let header = FrameHeader {
            seq: 7,
            ts_48k: 960,
            level_dbov: -20,
            flags: 0,
        };
        let mut frame = vec![3u8];
        frame.extend_from_slice(&client_frame(header, b"opus"));
        let (peer, parsed, opus) = parse_relay_frame(&frame).expect("parse");
        assert_eq!(peer, 3);
        assert_eq!(parsed, header);
        assert_eq!(opus, b"opus");

        let mut empty = vec![3u8];
        empty.extend_from_slice(&header.encode());
        assert!(parse_relay_frame(&empty).is_none());
        assert!(parse_relay_frame(&[3, 0, 0]).is_none());
    }

    #[test]
    fn out_of_range_level_is_clamped() {
        let mut bytes = FrameHeader {
            seq: 0,
            ts_48k: 0,
            level_dbov: 0,
            flags: 0,
        }
        .encode();
        bytes[6] = 0x7F;
        assert_eq!(
            FrameHeader::parse(&bytes).expect("parse").0.level_dbov,
            -127
        );
    }

    #[test]
    fn level_is_minus_127_for_silence_and_zero_at_full_scale() {
        assert_eq!(level_dbov(&[0; 480]), -127);
        assert_eq!(level_dbov(&[i16::MIN; 480]), 0);
        let speech: Vec<i16> = (0..480)
            .map(|i| ((i as f64 * 0.1).sin() * 3000.0) as i16)
            .collect();
        assert!((-40..=-10).contains(&level_dbov(&speech)));
    }
}
