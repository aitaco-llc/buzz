//! Model-backed relevance gate.
//!
//! A cheap classifier that decides whether an event is worth waking the
//! expensive agent harness for. It runs as the last step of
//! [`crate::filter::match_event`], only after the free checks (channel scope,
//! kind, mention, `evalexpr` filter) have already passed.
//!
//! # Why this exists
//!
//! An agent that hears a channel without requiring a mention wakes on every
//! message there. Measured on a six-agent team: one unmentioned message in a
//! shared channel started five agent sessions, four of which read it, decided
//! it was not their business, and ended the turn without publishing. That is
//! correct behaviour and five full context windows.
//!
//! The decision "is this mine?" is a classification, not reasoning. A 4B model
//! answers it in ~200ms against a local endpoint.
//!
//! # Why the gate is per-agent, not a central router
//!
//! The obvious alternative is one router that reads every message and mentions
//! the right agents. It is worse, and not only because of the extra identity
//! and relay hop: a router must ask "who should act?", which forces one model
//! to model the whole team. Two failures show up immediately — a question
//! spanning two machines routes to a specialist and misses the agent who owns
//! synthesis, and a message addressed to *everyone* routes to nobody because a
//! broadcast has no single domain owner.
//!
//! This gate asks a much easier question: "you are <this agent>; does this
//! require you to act?" Every agent independently answers yes to a broadcast,
//! and no agent has to model any other. The prompt is the agent's own system
//! prompt, which the harness already holds, so there is no roster in config to
//! drift out of date.
//!
//! # Fail open
//!
//! **This gate fails open, unlike every other check around it.**
//!
//! [`crate::filter::match_event`]'s `evalexpr` filter fails *closed*: any error
//! returns no match for any rule, because falling through would silently widen
//! the subscription. That is right for a subscription predicate.
//!
//! A relevance gate is a cost optimisation, not a security boundary. The
//! security boundaries — the author gate, `require_mention`, and channel
//! membership — all run before it and all still fail closed. If this gate
//! errors, times out, or returns something unparseable, the agent is woken:
//! back to the behaviour it would have had without a gate, which is expensive
//! but correct. Failing closed would degrade to silence, where the team looks
//! dead and nothing in the log says why.
//!
//! Set `on_error = "skip"` per rule to invert that for a channel where a
//! spurious wake costs more than a missed message. It is not the default.

use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::Mutex;
use std::time::Duration;

use tracing::{debug, warn};

/// Maximum cached verdicts. A broadcast fans out to one entry per rule, so a
/// small cap is enough to collapse retries and replayed events without letting
/// a long-running harness grow unbounded.
const CACHE_CAP: usize = 512;

/// Cap on the message text sent to the classifier. A relevance decision needs
/// the beginning of a message, never all of a pasted log, and an unbounded
/// prompt turns a 200ms gate into a multi-second one.
const MAX_CONTENT_CHARS: usize = 2_000;

fn default_timeout_ms() -> u64 {
    1_500
}

/// What to do when the gate cannot produce a verdict.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OnError {
    /// Wake the agent. The default, and the honest degradation: without a
    /// working gate the agent would have woken anyway.
    #[default]
    Wake,
    /// Drop the event. Only for a channel where a spurious wake is costlier
    /// than a missed message; accepts silence as a failure mode.
    Skip,
}

/// Per-rule gate configuration, deserialized from `[rules.relevance]`.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct RelevanceConfig {
    /// OpenAI-compatible base URL, e.g. `http://127.0.0.1:8077/v1`. The gate
    /// POSTs to `{endpoint}/chat/completions`.
    pub endpoint: String,
    /// Served model id.
    pub model: String,
    /// Wall-clock budget for one verdict.
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: u64,
    /// Behaviour when no verdict is available. See [`OnError`].
    #[serde(default)]
    pub on_error: OnError,
}

/// Process-wide gate state: one HTTP client, the agent's own purpose, and a
/// bounded verdict cache.
pub struct RelevanceGate {
    client: reqwest::Client,
    /// The agent's system prompt. This is what makes the gate per-agent.
    purpose: String,
    api_key: Option<String>,
    cache: Mutex<HashMap<u64, bool>>,
}

impl RelevanceGate {
    /// Build a gate. Returns `None` when the harness has no system prompt,
    /// because a gate with no notion of what the agent is for would classify
    /// on the message alone and is worse than no gate at all.
    pub fn new(purpose: Option<String>, api_key: Option<String>) -> Option<Self> {
        let purpose = purpose?;
        if purpose.trim().is_empty() {
            return None;
        }
        Some(Self {
            client: reqwest::Client::new(),
            purpose,
            api_key,
            cache: Mutex::new(HashMap::new()),
        })
    }

    /// Decide whether this event should wake the harness.
    ///
    /// Never returns an error: every failure path resolves through
    /// [`RelevanceConfig::on_error`], so a caller cannot forget to handle one.
    pub async fn wants(&self, cfg: &RelevanceConfig, rule_name: &str, content: &str) -> bool {
        let key = cache_key(&cfg.model, rule_name, content);
        if let Some(&hit) = self
            .cache
            .lock()
            .ok()
            .and_then(|c| c.get(&key).copied())
            .as_ref()
        {
            debug!(rule = %rule_name, verdict = hit, "relevance gate: cache hit");
            return hit;
        }

        let verdict = match self.ask(cfg, content).await {
            Ok(v) => {
                self.remember(key, v);
                v
            }
            Err(e) => {
                let fallback = matches!(cfg.on_error, OnError::Wake);
                // WARN, not DEBUG: a gate that is quietly failing is a gate
                // that is quietly costing money (on_error=wake) or quietly
                // losing messages (on_error=skip). Neither should be invisible.
                warn!(
                    rule = %rule_name,
                    error = %e,
                    on_error = ?cfg.on_error,
                    waking = fallback,
                    "relevance gate unavailable — falling back"
                );
                fallback
            }
        };

        debug!(rule = %rule_name, verdict, "relevance gate verdict");
        verdict
    }

    fn remember(&self, key: u64, verdict: bool) {
        if let Ok(mut cache) = self.cache.lock() {
            // Crude eviction: a verdict cache is an optimisation, and the
            // alternative — an LRU dependency for 512 bools — is not worth it.
            if cache.len() >= CACHE_CAP {
                cache.clear();
            }
            cache.insert(key, verdict);
        }
    }

    async fn ask(&self, cfg: &RelevanceConfig, content: &str) -> Result<bool, String> {
        let truncated: String = content.chars().take(MAX_CONTENT_CHARS).collect();

        let body = serde_json::json!({
            "model": cfg.model,
            "temperature": 0,
            "max_tokens": 120,
            "messages": [
                { "role": "system", "content": self.system_prompt() },
                { "role": "user", "content": format!("Message:\n{truncated}") },
            ],
            // Constrained decoding where the endpoint supports it. Endpoints
            // that ignore `response_format` still work: `parse_verdict` reads
            // the JSON out of free text.
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "relevance",
                    "schema": {
                        "type": "object",
                        "properties": {
                            "act": { "type": "boolean" },
                            "reason": { "type": "string" }
                        },
                        "required": ["act", "reason"]
                    }
                }
            }
        });

        let url = format!("{}/chat/completions", cfg.endpoint.trim_end_matches('/'));
        let mut req = self
            .client
            .post(&url)
            .timeout(Duration::from_millis(cfg.timeout_ms))
            .json(&body);
        if let Some(key) = &self.api_key {
            req = req.bearer_auth(key);
        }

        let resp = req.send().await.map_err(|e| e.to_string())?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| e.to_string())?;
        if !status.is_success() {
            return Err(format!(
                "{status}: {}",
                text.chars().take(200).collect::<String>()
            ));
        }

        let json: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        let message = json
            .pointer("/choices/0/message/content")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "no choices[0].message.content in response".to_string())?;

        parse_verdict(message)
    }

    fn system_prompt(&self) -> String {
        format!(
            "You decide whether a chat message requires a specific agent to act. \
             Reply ONLY with JSON: {{\"act\": <bool>, \"reason\": \"<short>\"}}.\n\n\
             The agent you are deciding for is described below. Answer `true` when \
             the message asks this agent to do something, concerns its own area of \
             responsibility, is addressed to the whole team (\"everyone\", \"all of \
             you\", \"each of you\"), or is a direct question it is best placed to \
             answer. Answer `false` for chatter, for work that belongs to a \
             different specialty, and for messages that need nobody.\n\n\
             When it is genuinely borderline, answer `true`: a missed request \
             stalls a person, while an unnecessary wake costs one quiet turn.\n\n\
             --- THE AGENT ---\n{}",
            self.purpose.chars().take(6_000).collect::<String>()
        )
    }
}

/// Extract `{"act": bool}` from a model reply.
///
/// Tolerates an endpoint that ignored `response_format` and wrapped the JSON in
/// prose or a fenced block, because an unparseable reply would otherwise become
/// an error and, under the default policy, a wake — the expensive outcome.
fn parse_verdict(raw: &str) -> Result<bool, String> {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(raw.trim()) {
        if let Some(act) = v.get("act").and_then(|a| a.as_bool()) {
            return Ok(act);
        }
    }
    let start = raw.find('{').ok_or_else(|| {
        format!(
            "no JSON object in reply: {}",
            raw.chars().take(120).collect::<String>()
        )
    })?;
    let end = raw
        .rfind('}')
        .ok_or_else(|| "unterminated JSON object in reply".to_string())?;
    if end <= start {
        return Err("malformed JSON object in reply".to_string());
    }
    let v: serde_json::Value =
        serde_json::from_str(&raw[start..=end]).map_err(|e| e.to_string())?;
    v.get("act")
        .and_then(|a| a.as_bool())
        .ok_or_else(|| "reply JSON has no boolean `act`".to_string())
}

fn cache_key(model: &str, rule_name: &str, content: &str) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    model.hash(&mut h);
    rule_name.hash(&mut h);
    content.hash(&mut h);
    h.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bare_json() {
        assert!(parse_verdict(r#"{"act": true, "reason": "mine"}"#).unwrap());
        assert!(!parse_verdict(r#"{"act": false, "reason": "not mine"}"#).unwrap());
    }

    #[test]
    fn parses_json_wrapped_in_prose_or_fences() {
        // An endpoint that ignores response_format must not turn into an error,
        // because an error becomes a wake and a wake is the expensive outcome.
        assert!(parse_verdict("Sure!\n```json\n{\"act\": true, \"reason\": \"x\"}\n```").unwrap());
        assert!(!parse_verdict("I think {\"act\": false, \"reason\": \"x\"} is right").unwrap());
    }

    #[test]
    fn rejects_replies_with_no_verdict() {
        assert!(parse_verdict("no json here").is_err());
        assert!(parse_verdict(r#"{"reason": "forgot the act field"}"#).is_err());
        assert!(parse_verdict(r#"{"act": "yes"}"#).is_err());
    }

    #[test]
    fn gate_requires_a_purpose() {
        // Without the agent's own prompt the gate would classify on the message
        // alone, which is worse than no gate.
        assert!(RelevanceGate::new(None, None).is_none());
        assert!(RelevanceGate::new(Some("   ".into()), None).is_none());
        assert!(RelevanceGate::new(Some("You are Scout.".into()), None).is_some());
    }

    #[test]
    fn on_error_defaults_to_wake() {
        let cfg: RelevanceConfig =
            serde_json::from_str(r#"{"endpoint":"http://x/v1","model":"m"}"#).unwrap();
        assert_eq!(cfg.on_error, OnError::Wake);
        assert_eq!(cfg.timeout_ms, 1_500);
    }

    #[test]
    fn cache_key_separates_agents_rules_and_models() {
        let a = cache_key("m1", "rule", "hello");
        assert_eq!(a, cache_key("m1", "rule", "hello"));
        assert_ne!(a, cache_key("m2", "rule", "hello"));
        assert_ne!(a, cache_key("m1", "other", "hello"));
        assert_ne!(a, cache_key("m1", "rule", "goodbye"));
    }
}
