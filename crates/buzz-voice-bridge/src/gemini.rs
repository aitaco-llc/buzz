//! Gemini Live API client (BidiGenerateContent over WebSocket).
//!
//! Wire shapes follow <https://ai.google.dev/api/live> and the Live guides
//! (read 2026-09-19): 16 kHz 16-bit PCM in, 24 kHz out, input and output
//! transcription, session resumption and sliding-window compression.
//! The key goes in the `x-goog-api-key` header so it never appears in a URL.

use anyhow::{anyhow, bail, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::time::Duration;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, http::HeaderValue, Message},
    MaybeTlsStream, WebSocketStream,
};

pub const DEFAULT_URL: &str = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";
pub const INPUT_RATE: u32 = 16_000;
pub const OUTPUT_RATE: u32 = 24_000;

/// The one tool Gemini gets. It hands a request to the rock seat and returns at
/// once; the answer comes back later as a user turn (see [`user_turn`]).
pub const ASK_ROCK: &str = "ask_rock";

#[derive(Debug, Clone)]
pub struct SessionConfig {
    pub model: String,
    pub system_instruction: String,
    pub voice: Option<String>,
}

pub fn setup_message(config: &SessionConfig, resume_handle: Option<&str>) -> Value {
    let model = if config.model.starts_with("models/") {
        config.model.clone()
    } else {
        format!("models/{}", config.model)
    };
    let mut generation = json!({ "responseModalities": ["AUDIO"] });
    if let Some(voice) = &config.voice {
        generation["speechConfig"] =
            json!({ "voiceConfig": { "prebuiltVoiceConfig": { "voiceName": voice } } });
    }
    let resumption = match resume_handle {
        Some(handle) => json!({ "handle": handle }),
        None => json!({}),
    };
    json!({
        "setup": {
            "model": model,
            "generationConfig": generation,
            "systemInstruction": { "parts": [{ "text": config.system_instruction }] },
            "tools": [{ "functionDeclarations": [{
                "name": ASK_ROCK,
                "description": "Hand a request to rock, the Claude seat with tools, repos, memory and the team. Use it for anything that needs a lookup, a decision, an action or a delegation, or that you are not sure of. It returns at once; rock's answer arrives later as a message that starts with \"rock answered\".",
                "parameters": {
                    "type": "OBJECT",
                    "properties": { "request": {
                        "type": "STRING",
                        "description": "Lloyd's request in his own words, with every detail he gave."
                    } },
                    "required": ["request"]
                }
            }] }],
            "inputAudioTranscription": {},
            "outputAudioTranscription": {},
            "sessionResumption": resumption,
            "contextWindowCompression": { "slidingWindow": {} }
        }
    })
}

pub fn audio_input(samples: &[i16]) -> Value {
    let mut bytes = Vec::with_capacity(samples.len() * 2);
    for sample in samples {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    json!({ "realtimeInput": { "audio": {
        "data": STANDARD.encode(bytes),
        "mimeType": format!("audio/pcm;rate={INPUT_RATE}")
    } } })
}

/// A complete user turn of text. `clientContent` is supported for the whole
/// session with explicit roles (Live guide, read 2026-09-19).
pub fn user_turn(text: &str) -> Value {
    json!({ "clientContent": {
        "turns": [{ "role": "user", "parts": [{ "text": text }] }],
        "turnComplete": true
    } })
}

pub fn tool_response(id: &str, name: &str, response: Value) -> Value {
    json!({ "toolResponse": { "functionResponses": [{
        "id": id, "name": name, "response": response
    }] } })
}

#[derive(Debug, Clone, PartialEq)]
pub struct FunctionCall {
    pub id: String,
    pub name: String,
    pub args: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServerEvent {
    SetupComplete,
    Audio(Vec<i16>),
    InputText(String),
    OutputText(String),
    Interrupted,
    TurnComplete,
    ToolCall(Vec<FunctionCall>),
    ToolCallCancellation(Vec<String>),
    ResumptionHandle(String),
    GoAway(Option<String>),
    Usage(Value),
    Error(String),
}

/// Parse one server message. One message can carry several events (audio,
/// transcription and `turnComplete` together), returned in wire order.
pub fn parse_server_message(value: &Value) -> Vec<ServerEvent> {
    let mut events = Vec::new();
    if value.get("setupComplete").is_some() {
        events.push(ServerEvent::SetupComplete);
    }
    if let Some(content) = value.get("serverContent") {
        if let Some(parts) = content["modelTurn"]["parts"].as_array() {
            for part in parts {
                let data = &part["inlineData"];
                if data["mimeType"]
                    .as_str()
                    .is_some_and(|m| m.starts_with("audio/pcm"))
                {
                    match data["data"].as_str().map(decode_pcm16) {
                        Some(Ok(samples)) if !samples.is_empty() => {
                            events.push(ServerEvent::Audio(samples))
                        }
                        Some(Err(error)) => events.push(ServerEvent::Error(format!(
                            "undecodable audio chunk: {error}"
                        ))),
                        _ => {}
                    }
                }
            }
        }
        if let Some(text) = content["inputTranscription"]["text"].as_str() {
            events.push(ServerEvent::InputText(text.to_owned()));
        }
        if let Some(text) = content["outputTranscription"]["text"].as_str() {
            events.push(ServerEvent::OutputText(text.to_owned()));
        }
        if content["interrupted"].as_bool() == Some(true) {
            events.push(ServerEvent::Interrupted);
        }
        if content["turnComplete"].as_bool() == Some(true) {
            events.push(ServerEvent::TurnComplete);
        }
    }
    if let Some(calls) = value["toolCall"]["functionCalls"].as_array() {
        events.push(ServerEvent::ToolCall(
            calls
                .iter()
                .map(|call| FunctionCall {
                    id: call["id"].as_str().unwrap_or_default().to_owned(),
                    name: call["name"].as_str().unwrap_or_default().to_owned(),
                    args: call["args"].clone(),
                })
                .collect(),
        ));
    }
    if let Some(ids) = value["toolCallCancellation"]["ids"].as_array() {
        events.push(ServerEvent::ToolCallCancellation(
            ids.iter()
                .filter_map(|id| id.as_str().map(str::to_owned))
                .collect(),
        ));
    }
    let update = &value["sessionResumptionUpdate"];
    if update["resumable"].as_bool() == Some(true) {
        if let Some(handle) = update["newHandle"].as_str().filter(|h| !h.is_empty()) {
            events.push(ServerEvent::ResumptionHandle(handle.to_owned()));
        }
    }
    if let Some(go_away) = value.get("goAway") {
        events.push(ServerEvent::GoAway(
            go_away["timeLeft"].as_str().map(str::to_owned),
        ));
    }
    if let Some(usage) = value.get("usageMetadata") {
        events.push(ServerEvent::Usage(usage.clone()));
    }
    if let Some(error) = value.get("error") {
        events.push(ServerEvent::Error(error.to_string()));
    }
    events
}

pub fn decode_pcm16(b64: &str) -> Result<Vec<i16>> {
    let bytes = STANDARD.decode(b64).context("base64")?;
    if bytes.len() % 2 != 0 {
        bail!("odd PCM16 byte count {}", bytes.len());
    }
    Ok(bytes
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect())
}

pub type GeminiStream = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

/// Open a session: connect, send `setup`, wait for `setupComplete`.
pub async fn connect(url: &str, api_key: &str, setup: &Value) -> Result<GeminiStream> {
    let mut request = url.into_client_request().context("Gemini URL")?;
    request.headers_mut().insert(
        "x-goog-api-key",
        HeaderValue::from_str(api_key).context("API key is not a valid header value")?,
    );
    let (mut ws, _) = tokio::time::timeout(Duration::from_secs(15), connect_async(request))
        .await
        .map_err(|_| anyhow!("Gemini connect timed out"))?
        .context("Gemini connect")?;
    ws.send(Message::Text(setup.to_string().into()))
        .await
        .context("send setup")?;
    let ready = tokio::time::timeout(Duration::from_secs(15), async {
        while let Some(message) = ws.next().await {
            let Some(value) = message_json(message.context("Gemini receive")?)? else {
                continue;
            };
            for event in parse_server_message(&value) {
                match event {
                    ServerEvent::SetupComplete => return Ok(()),
                    ServerEvent::Error(error) => bail!("Gemini setup error: {error}"),
                    _ => {}
                }
            }
        }
        bail!("Gemini closed the socket before setupComplete")
    })
    .await
    .map_err(|_| anyhow!("no setupComplete within 15 s"))?;
    ready?;
    Ok(ws)
}

/// Decode a WebSocket message into JSON. Gemini sends JSON in both text and
/// binary frames. Returns `Ok(None)` for control frames.
pub fn message_json(message: Message) -> Result<Option<Value>> {
    match message {
        Message::Text(text) => Ok(Some(serde_json::from_str(&text).context("Gemini JSON")?)),
        Message::Binary(bytes) => Ok(Some(serde_json::from_slice(&bytes).context("Gemini JSON")?)),
        Message::Close(frame) => bail!(
            "Gemini closed the session: {}",
            frame
                .map(|f| format!("{} {}", f.code, f.reason))
                .unwrap_or_default()
        ),
        _ => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setup_declares_one_tool_transcription_and_resumption() {
        let config = SessionConfig {
            model: "gemini-3.8-live".into(),
            system_instruction: "be brief".into(),
            voice: Some("Charon".into()),
        };
        let setup = setup_message(&config, None);
        let s = &setup["setup"];
        assert_eq!(s["model"], "models/gemini-3.8-live");
        assert_eq!(s["generationConfig"]["responseModalities"][0], "AUDIO");
        assert_eq!(
            s["generationConfig"]["speechConfig"]["voiceConfig"]["prebuiltVoiceConfig"]
                ["voiceName"],
            "Charon"
        );
        let tools = s["tools"][0]["functionDeclarations"]
            .as_array()
            .expect("tools");
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0]["name"], ASK_ROCK);
        assert!(s["inputAudioTranscription"].is_object());
        assert!(s["outputAudioTranscription"].is_object());
        assert_eq!(s["sessionResumption"], json!({}));
        assert!(s["contextWindowCompression"]["slidingWindow"].is_object());

        let resumed = setup_message(&config, Some("h1"));
        assert_eq!(resumed["setup"]["sessionResumption"]["handle"], "h1");
    }

    #[test]
    fn audio_input_is_little_endian_pcm_at_16k() {
        let message = audio_input(&[1, -2]);
        let audio = &message["realtimeInput"]["audio"];
        assert_eq!(audio["mimeType"], "audio/pcm;rate=16000");
        let bytes = STANDARD
            .decode(audio["data"].as_str().expect("data"))
            .expect("b64");
        assert_eq!(bytes, vec![0x01, 0x00, 0xFE, 0xFF]);
    }

    #[test]
    fn parses_audio_transcripts_and_turn_end_in_order() {
        let pcm = STANDARD.encode([0x01, 0x00, 0xFF, 0x7F]);
        let message = json!({ "serverContent": {
            "modelTurn": { "parts": [{ "inlineData": { "mimeType": "audio/pcm;rate=24000", "data": pcm } }] },
            "outputTranscription": { "text": "hi" },
            "turnComplete": true
        } });
        assert_eq!(
            parse_server_message(&message),
            vec![
                ServerEvent::Audio(vec![1, 32767]),
                ServerEvent::OutputText("hi".into()),
                ServerEvent::TurnComplete
            ]
        );
    }

    #[test]
    fn parses_tool_calls_resumption_and_go_away() {
        let call = json!({ "toolCall": { "functionCalls": [
            { "id": "c1", "name": "ask_rock", "args": { "request": "status?" } }
        ] } });
        assert_eq!(
            parse_server_message(&call),
            vec![ServerEvent::ToolCall(vec![FunctionCall {
                id: "c1".into(),
                name: "ask_rock".into(),
                args: json!({ "request": "status?" })
            }])]
        );
        let update = json!({ "sessionResumptionUpdate": { "newHandle": "h2", "resumable": true } });
        assert_eq!(
            parse_server_message(&update),
            vec![ServerEvent::ResumptionHandle("h2".into())]
        );
        let not_resumable =
            json!({ "sessionResumptionUpdate": { "newHandle": "h3", "resumable": false } });
        assert!(parse_server_message(&not_resumable).is_empty());
        assert_eq!(
            parse_server_message(&json!({ "goAway": { "timeLeft": "10s" } })),
            vec![ServerEvent::GoAway(Some("10s".into()))]
        );
        assert_eq!(
            parse_server_message(&json!({ "serverContent": { "interrupted": true } })),
            vec![ServerEvent::Interrupted]
        );
    }

    #[test]
    fn user_turn_and_tool_response_shapes() {
        assert_eq!(
            user_turn("rock answered: ok")["clientContent"]["turns"][0]["parts"][0]["text"],
            "rock answered: ok"
        );
        let response = tool_response("c1", "ask_rock", json!({ "status": "asked" }));
        let r = &response["toolResponse"]["functionResponses"][0];
        assert_eq!(r["id"], "c1");
        assert_eq!(r["response"]["status"], "asked");
    }
}
