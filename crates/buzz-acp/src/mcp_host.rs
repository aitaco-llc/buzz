//! An HTTP MCP endpoint the harness serves to its own ACP worker.
//!
//! Stage 2 of the Rebrand plan runs a worker (`rebrand-acp`) that must never
//! hold the seat's key, and whose reads must never leave the channel that
//! triggered the turn. Both follow from where the tools live: the harness keeps
//! the signer and serves the tools over loopback HTTP, and the worker gets a
//! URL and one bearer token per session.
//!
//! Why HTTP and not the stdio MCP the harness sends today (`acp.rs`): a stdio
//! MCP child is launched *by the worker*, so its environment — including any
//! credential it needs — crosses the worker's stdin in `session/new`. Over HTTP
//! the credential is a bearer for this endpoint alone, scoped to one channel,
//! and the relay key stays in this process.
//!
//! The shape is the one proven in `scripts/rebrand-proof/acp/host.rs` over 31
//! live runs against `rebrand serve`, narrowed to what a seat needs.

// Every item here is exercised by this module's tests and reached in production
// by the session wiring, which is the next change: a seat configured for a
// Rebrand worker starts one endpoint per session and sends its URL and bearer in
// `session/new`. The module lands first, with its guarantees under test, because
// it is the piece that holds the key inside this process.
#![allow(dead_code)]

use std::collections::HashSet;
use std::sync::Arc;

use tokio::sync::Mutex;

use axum::{
    body::Bytes,
    extract::State,
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
    Router,
};
use serde_json::{json, Value};
use uuid::Uuid;

use crate::relay::RestClient;

/// How many messages a single search may return. A small model does worse with
/// a long list, and the host pays for every one of them in the worker's context.
const SEARCH_LIMIT: usize = 8;

/// How many messages one thread read returns.
const THREAD_LIMIT: usize = 40;

/// The tools this endpoint serves, and the channel they are confined to.
///
/// One instance serves one ACP session, so the channel cannot change under a
/// running turn: a new trigger in another channel gets its own endpoint and its
/// own token.
pub(crate) struct McpTools {
    rest: RestClient,
    channel_id: Uuid,
    /// Message IDs a search in this session actually returned. `read_thread`
    /// accepts nothing else, so the worker cannot read an event it was never
    /// shown — not a guessed ID, and not one lifted from the question's text.
    seen: Mutex<HashSet<String>>,
}

impl McpTools {
    pub(crate) fn new(rest: RestClient, channel_id: Uuid) -> Self {
        Self {
            rest,
            channel_id,
            seen: Mutex::new(HashSet::new()),
        }
    }

    /// Every read goes through here, so the channel scope is applied in one
    /// place and checked again on the way out: the filter carries `#h`, and each
    /// row's own `h` tag must still name this channel. A relay that answered
    /// with someone else's channel fails the call rather than reaching the model.
    async fn query(&self, mut filter: Value, limit: usize) -> Result<Vec<Value>, String> {
        filter["kinds"] = json!([
            buzz_core::kind::KIND_STREAM_MESSAGE,
            buzz_core::kind::KIND_STREAM_MESSAGE_V2
        ]);
        filter["#h"] = json!([self.channel_id.to_string()]);
        filter["limit"] = json!(limit);
        let rows = self
            .rest
            .query_raw(&[filter])
            .await
            .map_err(|e| format!("relay read failed: {e}"))?;
        let rows = rows.as_array().ok_or("relay did not answer with events")?;
        let mut out = Vec::with_capacity(rows.len().min(limit));
        let mut seen = self.seen.lock().await;
        for row in rows.iter().take(limit) {
            let id = row["id"].as_str().ok_or("event without an id")?;
            if !is_event_id(id) {
                return Err("event with a malformed id".into());
            }
            if !in_channel(row, &self.channel_id.to_string()) {
                return Err("relay answered with another channel's message".into());
            }
            seen.insert(id.to_owned());
            out.push(json!({
                "id": id,
                "content": row["content"],
                "author": row["pubkey"],
                "created_at": row["created_at"],
                "tags": row["tags"],
            }));
        }
        Ok(out)
    }

    /// `search_messages`.
    async fn search(&self, args: &Value) -> Result<Value, String> {
        let query = args["query"].as_str().unwrap_or_default().trim();
        if query.is_empty() || query.len() > 256 {
            return Err("query must be 1–256 bytes of text".into());
        }
        let hits = self.query(json!({"search": query}), SEARCH_LIMIT).await?;
        // The opening of each hit, not the whole message: enough for the model
        // to choose a thread, and it keeps a long channel out of its context.
        let brief: Vec<Value> = hits
            .iter()
            .map(|row| {
                let text = row["content"].as_str().unwrap_or_default();
                let head: String = text.chars().take(240).collect();
                json!({"id": row["id"], "opening": head})
            })
            .collect();
        Ok(json!({"matches": brief}))
    }

    /// `read_thread`: the named message, its root if it has one, and the replies
    /// under that root — all inside this channel.
    async fn read_thread(&self, args: &Value) -> Result<Value, String> {
        let event_id = args["event_id"].as_str().unwrap_or_default();
        if !is_event_id(event_id) {
            return Err("event_id must be a 64-character message ID from search_messages".into());
        }
        if !self.seen.lock().await.contains(event_id) {
            return Err(
                "that ID did not come from search_messages in this session; search first".into(),
            );
        }
        let mut rows = self.query(json!({"ids": [event_id]}), 1).await?;
        let selected = rows.first().ok_or("that message is no longer readable")?;
        let root = thread_root(selected).unwrap_or_else(|| event_id.to_owned());
        if !is_event_id(&root) {
            return Err("that message names a malformed thread root".into());
        }
        if root != event_id {
            rows.extend(self.query(json!({"ids": [root]}), 1).await?);
        }
        rows.extend(self.query(json!({"#e": [root]}), THREAD_LIMIT).await?);
        Ok(json!({"messages": rows}))
    }

    /// `tools/list`. Both tools, always: unlike the proof host, a seat does not
    /// narrow by turn state, because a general question may need either one at
    /// any point, and a one-value `enum` of found IDs measured badly — the model
    /// read the list as the answer set (`RESEARCH/REBRAND_ACP_PROOF_31FC194_2026-09-19.md`).
    pub(crate) fn list(&self) -> Value {
        json!([
            {
                "name": "search_messages",
                "description": "Search this channel's messages. Returns each match's relay message ID with \
                    the opening of its text, newest first. The IDs are opaque 64-character identifiers: pass \
                    one to read_thread to read that message and its replies.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Words expected in the message text, not an identifier.",
                        },
                    },
                    "required": ["query"],
                    "additionalProperties": false,
                },
            },
            {
                "name": "read_thread",
                "description": "Read a message and its replies. Takes one of the 64-character message IDs \
                    search_messages returned; any other identifier is refused, including one named in the \
                    question, because those live inside the text rather than as message IDs.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "event_id": {
                            "type": "string",
                            "description": "A 64-character message ID from search_messages.",
                        },
                    },
                    "required": ["event_id"],
                    "additionalProperties": false,
                },
            },
        ])
    }
}

/// The thread a message belongs to: its `root` marker, else its `reply` marker,
/// else nothing — the message is its own root.
fn thread_root(row: &Value) -> Option<String> {
    let tags = row["tags"].as_array()?;
    let marked = |marker: &str| {
        tags.iter()
            .find(|t| t[0] == "e" && t[3] == marker)
            .and_then(|t| t[1].as_str())
            .map(str::to_owned)
    };
    marked("root").or_else(|| marked("reply"))
}

/// Whether a row's own `h` tag names the channel we asked for.
fn in_channel(row: &Value, channel: &str) -> bool {
    row["tags"]
        .as_array()
        .is_some_and(|tags| tags.iter().any(|t| t[0] == "h" && t[1] == channel))
}

/// Lowercase 64-hex, the only shape a Nostr event ID takes. Checked before any
/// relay call so a malformed argument costs no round trip.
pub(crate) fn is_event_id(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// One session's endpoint: the tools, and the bearer that reaches them.
pub(crate) struct McpEndpoint {
    tools: Arc<McpTools>,
    token: String,
}

/// Constant-time-ish comparison of the presented bearer against ours. Lengths
/// are equal for every token we mint, so a length check leaks nothing useful,
/// and the byte fold avoids an early return on the first wrong byte.
fn bearer_matches(presented: Option<&str>, expected: &str) -> bool {
    let Some(presented) = presented.and_then(|v| v.strip_prefix("Bearer ")) else {
        return false;
    };
    if presented.len() != expected.len() {
        return false;
    }
    presented
        .bytes()
        .zip(expected.bytes())
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0
}

/// JSON-RPC: the method does not exist.
const METHOD_NOT_FOUND: i64 = -32601;
/// JSON-RPC: the method exists and its params are wrong (an unknown tool name).
const INVALID_PARAMS: i64 = -32602;

/// MCP protocol versions this endpoint speaks, newest first. `initialize`
/// answers with the client's version when it is one of these, and with the
/// newest otherwise, as the spec asks — never with an arbitrary echo.
const PROTOCOL_VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

/// The version to answer `initialize` with.
fn negotiated_version(requested: Option<&str>) -> &'static str {
    requested
        .and_then(|asked| PROTOCOL_VERSIONS.iter().find(|v| **v == asked))
        .copied()
        .unwrap_or(PROTOCOL_VERSIONS[0])
}

/// The JSON-RPC surface `of-mcp`'s Streamable HTTP client speaks. An unknown
/// method is `-32601` and an unknown tool `-32602`: a worker that asks for a
/// capability we do not serve should fail its run rather than continue with a
/// silent gap.
pub(crate) async fn dispatch(
    tools: &McpTools,
    method: &str,
    params: &Value,
) -> Result<Value, (i64, String)> {
    match method {
        "initialize" => Ok(json!({
            "protocolVersion": negotiated_version(params["protocolVersion"].as_str()),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "buzz-acp", "version": env!("CARGO_PKG_VERSION")},
        })),
        // of-mcp sends these with an ID and ignores the result.
        "ping" | "notifications/initialized" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tools.list()})),
        "tools/call" => {
            let name = params["name"].as_str().unwrap_or_default();
            let args = params.get("arguments").cloned().unwrap_or(json!({}));
            let outcome = match name {
                "search_messages" => tools.search(&args).await,
                "read_thread" => tools.read_thread(&args).await,
                other => {
                    return Err((
                        INVALID_PARAMS,
                        format!("{other:?} is not a tool served here"),
                    ))
                }
            };
            // A refused call is the model's to read and retry, as any tool error
            // is — `isError` keeps it inside the turn instead of ending it.
            Ok(match outcome {
                Ok(value) => {
                    json!({"content": [{"type": "text", "text": value.to_string()}], "isError": false})
                }
                Err(message) => {
                    json!({"content": [{"type": "text", "text": message}], "isError": true})
                }
            })
        }
        other => Err((METHOD_NOT_FOUND, format!("{other:?} is not served here"))),
    }
}

async fn handle(
    State(endpoint): State<Arc<McpEndpoint>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    if !bearer_matches(
        headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok()),
        &endpoint.token,
    ) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Ok(request) = serde_json::from_slice::<Value>(&body) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    // A notification (no id) is accepted and answered with nothing.
    let Some(id) = request.get("id").cloned() else {
        return StatusCode::ACCEPTED.into_response();
    };
    let method = request["method"].as_str().unwrap_or_default();
    let params = request.get("params").cloned().unwrap_or(json!({}));
    match dispatch(&endpoint.tools, method, &params).await {
        Ok(result) => {
            axum::Json(json!({"jsonrpc": "2.0", "id": id, "result": result})).into_response()
        }
        Err((code, message)) => axum::Json(json!({
            "jsonrpc": "2.0", "id": id,
            "error": {"code": code, "message": message},
        }))
        .into_response(),
    }
}

/// Mint a token with no structure to guess: two UUIDv4s, 64 hex characters.
fn mint_token() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

/// The serving task of one endpoint. Dropping it stops the task and closes
/// the listener, so the endpoint — its port, its bearer and the seat's signing
/// client — lives exactly as long as the session that holds the guard. A bare
/// `JoinHandle` would not do this: dropping one detaches the task, and every
/// session would leave a live, authenticated listener behind until the
/// process exits.
pub(crate) struct EndpointGuard(tokio::task::JoinHandle<()>);

impl Drop for EndpointGuard {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Start an endpoint on loopback and return its URL, bearer and guard.
///
/// The listener binds `127.0.0.1:0`: a port the kernel picks, reachable only
/// from this machine. Dropping the returned [`EndpointGuard`] closes it.
pub(crate) async fn serve(
    rest: RestClient,
    channel_id: Uuid,
) -> Result<(String, String, EndpointGuard), std::io::Error> {
    let token = mint_token();
    let endpoint = Arc::new(McpEndpoint {
        tools: Arc::new(McpTools::new(rest, channel_id)),
        token: token.clone(),
    });
    let app = Router::new()
        .route("/mcp", post(handle))
        .with_state(endpoint);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("http://{}/mcp", listener.local_addr()?);
    let handle = tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app).await {
            tracing::warn!(target: "mcp_host", "MCP endpoint stopped: {e}");
        }
    });
    Ok((url, token, EndpointGuard(handle)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tools() -> McpTools {
        let keys = nostr::Keys::generate();
        McpTools::new(
            RestClient {
                http: reqwest::Client::new(),
                base_url: "http://127.0.0.1:1/".into(),
                keys,
                auth_tag_json: None,
            },
            Uuid::nil(),
        )
    }

    #[test]
    fn only_the_right_bearer_opens_the_endpoint() {
        let token = mint_token();
        assert_eq!(token.len(), 64, "two UUIDv4s, hex, no separators");
        assert!(bearer_matches(Some(&format!("Bearer {token}")), &token));
        assert!(
            !bearer_matches(Some(&token), &token),
            "the scheme is required"
        );
        assert!(!bearer_matches(None, &token));
        assert!(!bearer_matches(Some("Bearer "), &token));
        assert!(!bearer_matches(
            Some(&format!("Bearer {}", "0".repeat(64))),
            &token
        ));
        // A prefix of the right token is not the right token.
        assert!(!bearer_matches(
            Some(&format!("Bearer {}", &token[..63])),
            &token
        ));
    }

    #[test]
    fn an_event_id_is_lowercase_64_hex() {
        assert!(is_event_id(&"a".repeat(64)));
        assert!(is_event_id("0123456789abcdef".repeat(4).as_str()));
        assert!(!is_event_id(&"a".repeat(63)), "too short");
        assert!(
            !is_event_id(&"A".repeat(64)),
            "uppercase is not what the relay returns"
        );
        assert!(!is_event_id(&"g".repeat(64)), "not hex");
        assert!(
            !is_event_id("f0351dc5-9307-45e2-a43f-180c234a838f"),
            "a channel UUID is not an event"
        );
    }

    #[test]
    fn a_thread_root_prefers_the_root_marker() {
        let root = "b".repeat(64);
        let reply = "c".repeat(64);
        let row = json!({"tags": [["e", reply, "", "reply"], ["e", root, "", "root"]]});
        assert_eq!(thread_root(&row).as_deref(), Some(root.as_str()));
        let only_reply = json!({"tags": [["e", reply, "", "reply"]]});
        assert_eq!(thread_root(&only_reply).as_deref(), Some(reply.as_str()));
        assert_eq!(
            thread_root(&json!({"tags": [["h", "x"]]})),
            None,
            "a top-level post is its own root"
        );
    }

    #[test]
    fn a_row_must_carry_this_channels_h_tag() {
        let mine = "f0351dc5-9307-45e2-a43f-180c234a838f";
        assert!(in_channel(&json!({"tags": [["h", mine]]}), mine));
        assert!(!in_channel(&json!({"tags": [["h", "another"]]}), mine));
        assert!(!in_channel(&json!({"tags": []}), mine));
        assert!(!in_channel(&json!({}), mine));
    }

    /// The structural lesson from the 31fc194 and 530cd1f batches, as an
    /// assertion: no `enum` of found IDs. The model read that list as the set of
    /// candidate answers and stopped calling the tool.
    #[tokio::test]
    async fn read_thread_takes_a_plain_string_and_both_tools_are_always_offered() {
        let tools = tools();
        let listed = tools.list();
        let names: Vec<&str> = listed
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["search_messages", "read_thread"]);
        let event_id = &listed[1]["inputSchema"]["properties"]["event_id"];
        assert_eq!(event_id["type"], "string");
        assert!(
            event_id.get("enum").is_none(),
            "an enum of found IDs reads as the answer set"
        );
    }

    #[tokio::test]
    async fn an_unknown_method_is_method_not_found() {
        let tools = tools();
        assert_eq!(
            dispatch(&tools, "resources/list", &json!({}))
                .await
                .unwrap_err()
                .0,
            METHOD_NOT_FOUND
        );
        assert_eq!(
            dispatch(&tools, "tools/call", &json!({"name": "shell"}))
                .await
                .unwrap_err()
                .0,
            INVALID_PARAMS,
            "the method exists; the tool name is the bad param"
        );
        assert!(dispatch(&tools, "ping", &json!({})).await.is_ok());
        let initialized = dispatch(
            &tools,
            "initialize",
            &json!({"protocolVersion": "2025-06-18"}),
        )
        .await
        .expect("initialize is served");
        assert_eq!(initialized["protocolVersion"], "2025-06-18");
        assert_eq!(initialized["capabilities"]["tools"], json!({}));
    }

    /// No search has run, so no ID can have come from one — the check that
    /// replaces the `enum`.
    #[tokio::test]
    async fn read_thread_refuses_an_id_no_search_returned() {
        let tools = tools();
        let called = dispatch(
            &tools,
            "tools/call",
            &json!({"name": "read_thread", "arguments": {"event_id": "a".repeat(64)}}),
        )
        .await
        .expect("a refused tool call is a result, not a protocol error");
        assert_eq!(called["isError"], true);
        let text = called["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("search first"), "{text}");
    }

    #[tokio::test]
    async fn the_endpoint_binds_loopback_and_refuses_the_wrong_bearer() {
        let keys = nostr::Keys::generate();
        let rest = RestClient {
            http: reqwest::Client::new(),
            base_url: "http://127.0.0.1:1/".into(),
            keys,
            auth_tag_json: None,
        };
        let (url, token, handle) = serve(rest, Uuid::nil()).await.expect("endpoint binds");
        assert!(url.starts_with("http://127.0.0.1:"), "{url}");
        let client = reqwest::Client::new();
        let body = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"});
        let unauthorized = client
            .post(&url)
            .json(&body)
            .send()
            .await
            .expect("request sent");
        assert_eq!(unauthorized.status().as_u16(), 401);
        let wrong = client
            .post(&url)
            .header("Authorization", format!("Bearer {}", "0".repeat(64)))
            .json(&body)
            .send()
            .await
            .expect("request sent");
        assert_eq!(wrong.status().as_u16(), 401);
        let ok: Value = client
            .post(&url)
            .header("Authorization", format!("Bearer {token}"))
            .json(&body)
            .send()
            .await
            .expect("request sent")
            .json()
            .await
            .expect("json body");
        assert_eq!(ok["result"]["tools"].as_array().unwrap().len(), 2);

        // Dropping the guard is what ends a session's endpoint: after it, the
        // bearer that worked a moment ago reaches nothing.
        drop(handle);
        let mut closed = false;
        for _ in 0..50 {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            let after = client
                .post(&url)
                .header("Authorization", format!("Bearer {token}"))
                .json(&body)
                .timeout(std::time::Duration::from_millis(500))
                .send()
                .await;
            if after.is_err() {
                closed = true;
                break;
            }
        }
        assert!(
            closed,
            "the endpoint must stop serving once its guard is dropped"
        );
    }

    #[test]
    fn initialize_answers_with_a_version_it_speaks() {
        assert_eq!(negotiated_version(Some("2025-03-26")), "2025-03-26");
        assert_eq!(negotiated_version(Some("1999-01-01")), PROTOCOL_VERSIONS[0]);
        assert_eq!(negotiated_version(None), PROTOCOL_VERSIONS[0]);
    }
}
