//! Pre-turn task extraction.
//!
//! Turns one of the owner's messages into zero or more tasks, in the harness,
//! at trigger receipt, before the seat's model turn is queued.
//!
//! # Why the harness
//!
//! `PLANS/BUZZ_TASK_TRACKER_ARCHITECTURE_2026-09-23.md` §5 and
//! `scripts/task-extractor/README.md` give the argument in full. The short
//! version: a relay workflow cannot read DMs, a clerk seat cannot either, and
//! the audit's first dropped item was a DM. The addressed seat's harness is the
//! only process that holds the plaintext, is alive while the model is
//! limit-held, and does not depend on a persona remembering to do it.
//!
//! The load-bearing consequence, from the corpus: **zero of the eleven readable
//! utterances carry a `p` tag**. The owner addresses people in prose and posts
//! top level. So extraction must not sit downstream of the subscription rules
//! that decide whether this seat was addressed — a seat that is not woken still
//! has to capture the work.
//!
//! # 0..N, not 0..1
//!
//! One message produces a *list*. The two utterances in the audit window that
//! lost the most work are both multi-task, and one lost work inside itself: the
//! audit's own line for `6bfd1e01` reads "audio was never dispatched to
//! Nathaniel; iOS hardware validation was never dispatched to Woody", which is
//! two sub-items a one-task extraction swallows by construction.
//!
//! # Fail open, and fail quiet
//!
//! Like [`crate::relevance`], this is not a security boundary. Every failure
//! path — timeout, transport error, unparseable reply, a task that fails
//! validation — drops the extraction and lets the turn proceed. A seat that
//! cannot extract must still answer.
//!
//! Unlike the relevance gate, "fail open" here means *publish nothing*, because
//! the expensive mistake is a board full of tasks nobody can close. A record
//! that names the wrong thing is worse than no record — the same posture as the
//! NIP-AR receipt.

use std::collections::HashSet;
use std::time::Duration;

use tracing::{debug, warn};

/// Cap on the message text sent to the extractor.
///
/// An ask lives in the message; a pasted log appended to it does not change
/// what was asked. Matching [`crate::relevance::MAX_CONTENT_CHARS`] in spirit,
/// larger because an extraction has to read the whole ask, not just recognise
/// its subject.
const MAX_CONTENT_CHARS: usize = 6_000;

/// Cap on one thread-context entry.
const MAX_CONTEXT_ENTRY_CHARS: usize = 600;

/// Cap on how many thread-context entries are sent.
const MAX_CONTEXT_ENTRIES: usize = 8;

/// Cap on how many open tasks are offered as attach targets.
///
/// The board is the only thing that makes `attach` decidable, so it cannot be
/// dropped — but an unbounded board turns a cheap call into an expensive one
/// and buries the relevant row.
const MAX_BOARD_ENTRIES: usize = 40;

/// The NIP-34 subject tag's practical limit. A subject longer than this is a
/// description, and it is rejected rather than truncated: a silently clipped
/// subject reads as a deliberate one.
const MAX_SUBJECT_CHARS: usize = 256;

/// Configuration for the extractor's model call.
///
/// Deliberately the same shape as [`crate::relevance::RelevanceConfig`]: an
/// OpenAI-compatible endpoint, a served model id, and a hard wall clock. The
/// model is Rebrand or Flash, never the seat's Claude subscription, so a Claude
/// limit hold cannot block capture.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct TaskExtractConfig {
    /// OpenAI-compatible base URL. The extractor POSTs to
    /// `{endpoint}/chat/completions`.
    pub endpoint: String,
    /// Served model id.
    pub model: String,
    /// Wall-clock budget for one extraction.
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: u64,
    /// Token budget for one reply.
    ///
    /// **A thinking model spends this budget before it writes anything.**
    /// Measured on `gemini-3.8-flash` against this prompt: ~1000 thinking
    /// tokens for ~200 of JSON, and a harder message spends more. At 1600 the
    /// reply came back truncated mid-object on 5 of the 11 corpus utterances —
    /// which parses as a transport failure, not as a short answer. Leave
    /// headroom.
    #[serde(default = "default_max_tokens")]
    pub max_tokens: u32,
    /// OpenAI-style `reasoning_effort`, sent only when set.
    ///
    /// **Defaults to unset, and that is a measured choice against an obvious
    /// one.** Constraining it to `low` cuts thinking ~5× on
    /// `gemini-3.8-flash` (619 tokens → 126 on the corpus's hardest
    /// utterance), which looks like a pure win for latency and truncation.
    /// It is not: decomposition is the thinking. At `low` the same model
    /// returned **one** task for a message asking four, and mistook two
    /// board-status questions for new work — 7/11 on the corpus and the gate
    /// failed. Unset, with the same prompt and the same retries: 4 tasks for
    /// the four-ask message, and the gate passed.
    ///
    /// Truncation is the right thing to fix with [`Self::attempts`] and a
    /// budget that doubles, not by taking away the model's ability to count.
    ///
    /// Set it explicitly for an endpoint whose defaults are expensive, and
    /// re-run the corpus gate when you do.
    #[serde(default)]
    pub reasoning_effort: Option<String>,
    /// How many times to ask before giving up.
    ///
    /// Not politeness — measured necessity. Three consecutive replays of the
    /// eleven-utterance corpus through `gemini-3.8-flash` failed on
    /// `6bfd1e01`, then `17ced753`, then `46c1401d` and `5872666e`: **a
    /// different utterance every time**, at roughly one or two calls in eleven.
    /// Truncation and Gemini's `RECITATION` content filter are both transient
    /// and neither correlates with the message. A single-shot extractor
    /// therefore drops about one ask in eight for no reason anyone could name
    /// afterwards, because a failed call publishes nothing and looks exactly
    /// like "no work here".
    ///
    /// Each retry doubles [`Self::max_tokens`], which is free when the failure
    /// was not a truncation and is the fix when it was.
    #[serde(default = "default_attempts")]
    pub attempts: u32,
}

fn default_timeout_ms() -> u64 {
    20_000
}

fn default_max_tokens() -> u32 {
    8_000
}

fn default_attempts() -> u32 {
    3
}

/// The message being extracted from.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SourceMessage {
    /// Full 64-hex event id. This is the idempotency key.
    pub id: String,
    /// Channel UUID.
    pub channel: String,
    /// Author pubkey, 64-hex.
    pub author: String,
    /// The message text.
    pub text: String,
    /// NIP-10 thread root, when the message is a reply.
    #[serde(default)]
    pub thread_root: Option<String>,
}

/// One open task offered as an `attach` target.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct BoardTask {
    /// Issue event id.
    pub id: String,
    pub subject: String,
    pub state: String,
    #[serde(default)]
    pub assignee: Option<String>,
}

/// Everything the extractor is allowed to see.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ExtractInput {
    pub message: Option<SourceMessage>,
    /// The thread root's text and the last few replies, oldest first.
    #[serde(default)]
    pub thread_context: Vec<String>,
    /// Open tasks. The only source of legal `attachTo` ids.
    #[serde(default)]
    pub board: Vec<BoardTask>,
}

/// One extracted action.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub enum TaskAction {
    Create {
        subject: String,
        why: String,
        done_when: String,
        assignee: Option<String>,
        /// Index into the same extraction's list. `Some(i)` means "this is
        /// blocked by entry `i`", which is how an ordered ask keeps its order.
        blocked_by: Option<usize>,
    },
    Attach {
        /// Must be an id from the supplied board.
        attach_to: String,
        note: String,
    },
}

/// The reduction the eval scores: one action label and a task count per
/// utterance.
///
/// `scripts/task-extractor/task-extractor-eval.py` reads
/// `{"<8-hex id>": {"action", "count"}}`. A list collapses to that as follows,
/// and the order matters: a message that both creates and attaches is a
/// `create`, because the create is the work that would otherwise go missing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase", tag = "action")]
pub enum Verdict {
    Create { count: usize },
    Attach { count: usize },
    None { count: usize },
}

/// A task that did not survive validation, kept so the drop is loggable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dropped {
    pub index: usize,
    pub reason: String,
}

/// The result of one extraction.
///
/// `error` is the difference between *"the model read this and decided there is
/// no work here"* and *"the extractor never got an answer"*. Both publish
/// nothing, so both look identical downstream — and a replay that cannot tell
/// them apart scores a transport failure as a model verdict. It did, once, on
/// the first run of the corpus: four `none`s that were really a prompt the model
/// never answered. Keep them distinguishable.
#[derive(Debug, Clone, Default)]
pub struct Extraction {
    pub tasks: Vec<TaskAction>,
    pub dropped: Vec<Dropped>,
    /// `Some` when no verdict was obtained at all. An empty `tasks` with
    /// `error: None` is a decision; with `error: Some` it is a failure.
    pub error: Option<String>,
    /// The model's own enumeration of what the message asked for. Diagnostic
    /// only — never published. When `asks.len()` exceeds `tasks.len()`, the
    /// model saw work it then failed to emit, which is the undercount this
    /// field exists to make visible.
    pub asks: Vec<String>,
}

impl Extraction {
    /// An extraction that never got an answer.
    pub fn failed(reason: impl Into<String>) -> Self {
        Self { error: Some(reason.into()), ..Default::default() }
    }
}

impl Extraction {
    /// Collapse to the eval's `(action, count)` shape.
    pub fn verdict(&self) -> Verdict {
        let creates = self
            .tasks
            .iter()
            .filter(|t| matches!(t, TaskAction::Create { .. }))
            .count();
        if creates > 0 {
            return Verdict::Create { count: creates };
        }
        let attaches = self.tasks.len();
        if attaches > 0 {
            return Verdict::Attach { count: attaches };
        }
        Verdict::None { count: 0 }
    }
}

/// Process-wide extractor state: one HTTP client and the seat roster used to
/// validate an `assignee`.
pub struct TaskExtractor {
    client: reqwest::Client,
    api_key: Option<String>,
    /// 64-hex pubkeys an `assignee` may name. An assignee outside this set is
    /// dropped rather than published, because an assignment that names nobody
    /// is invisible on the board's "assigned to me" filter and reads as
    /// unassigned forever.
    known_pubkeys: HashSet<String>,
}

impl TaskExtractor {
    pub fn new(api_key: Option<String>, known_pubkeys: HashSet<String>) -> Self {
        Self {
            client: reqwest::Client::new(),
            api_key,
            known_pubkeys,
        }
    }

    /// Run one extraction. Never returns an error: every failure resolves to an
    /// empty [`Extraction`] and a warn line, because capture is important and
    /// blocking a reply on it is not.
    pub async fn extract(&self, cfg: &TaskExtractConfig, input: &ExtractInput) -> Extraction {
        let mut attempt = 0;
        let mut budget = cfg.max_tokens;
        let mut last_error = String::from("no attempt was made");
        let raw = loop {
            attempt += 1;
            if attempt > cfg.attempts.max(1) {
                break Err(last_error);
            }
            let try_cfg = TaskExtractConfig { max_tokens: budget, ..cfg.clone() };
            // First ask is greedy; a retry must take a DIFFERENT path through
            // the model or it is not a retry at all. Gemini's `RECITATION`
            // content filter is a property of the sampled continuation, so
            // three identical greedy calls are blocked three identical times —
            // measured on `46c1401d`, which lost all three attempts at
            // temperature 0 and answered on the first non-greedy one.
            let temperature = if attempt == 1 { 0.0 } else { 0.4 };
            match self.ask(&try_cfg, input, temperature).await {
                Ok(raw) => break Ok(raw),
                Err(e) => {
                    warn!(
                        attempt,
                        of = cfg.attempts.max(1),
                        budget,
                        error = %e,
                        "task extraction attempt failed"
                    );
                    last_error = e;
                    // Free when the failure was not a truncation, and the fix
                    // when it was.
                    budget = budget.saturating_mul(2);
                }
            }
        };
        match raw {
            Ok((asks, raw)) => {
                if !asks.is_empty() {
                    debug!(asks = asks.len(), "task extraction enumerated the asks");
                }
                let mut extraction = validate(raw, input, &self.known_pubkeys);
                extraction.asks = asks;
                for d in &extraction.dropped {
                    warn!(
                        index = d.index,
                        reason = %d.reason,
                        "task extraction dropped a task that failed validation"
                    );
                }
                debug!(
                    tasks = extraction.tasks.len(),
                    dropped = extraction.dropped.len(),
                    "task extraction complete"
                );
                extraction
            }
            Err(e) => {
                warn!(error = %e, "task extraction failed — turn proceeds with no extraction");
                Extraction::failed(e)
            }
        }
    }

    async fn ask(
        &self,
        cfg: &TaskExtractConfig,
        input: &ExtractInput,
        temperature: f64,
    ) -> Result<(Vec<String>, Vec<RawTask>), String> {
        let mut body = serde_json::json!({
            "model": cfg.model,
            "temperature": temperature,
            "max_tokens": cfg.max_tokens,
            "messages": [
                { "role": "system", "content": SYSTEM_PROMPT },
                { "role": "user", "content": render_input(input) },
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": { "name": "extraction", "schema": output_schema() }
            }
        });

        if let (Some(effort), Some(map)) = (&cfg.reasoning_effort, body.as_object_mut()) {
            map.insert(
                "reasoning_effort".to_string(),
                serde_json::Value::String(effort.clone()),
            );
        }

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
        // Check this BEFORE parsing. A reply cut off at the token budget is a
        // half-written JSON object, and `parse_tasks` can only report that as
        // malformed — which sends whoever reads the log hunting a model bug
        // instead of raising a budget. Name the real cause here.
        let finish = json
            .pointer("/choices/0/finish_reason")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if finish == "length" {
            return Err(format!(
                "reply truncated at the {}-token budget (finish_reason=length); \
                 a thinking model spends this budget before it writes",
                cfg.max_tokens
            ));
        }
        let message = json
            .pointer("/choices/0/message/content")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                format!("no choices[0].message.content in response (finish_reason={finish})")
            })?;
        parse_tasks(message)
    }
}

/// The JSON schema handed to the endpoint for constrained decoding.
///
/// Endpoints that ignore `response_format` still work: [`parse_tasks`] reads
/// the JSON out of free text, exactly as the relevance gate does.
pub fn output_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "object",
        "properties": {
            // Step 1 as an output field rather than an instruction.
            //
            // The prompt already told the model to enumerate the asks before
            // classifying them. Measured over five corpus replays it did not:
            // `6bfd1e01`, a message with three asks in three clauses, came back
            // as 1, 1, none, 3, none. An enumeration the model has to WRITE is
            // one it has to do. The harness never publishes this field; it is
            // there to be filled in.
            "asks": { "type": "array", "items": { "type": "string" } },
            "tasks": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "action":    { "type": "string", "enum": ["create", "attach"] },
                        "subject":   { "type": "string" },
                        "why":       { "type": "string" },
                        "doneWhen":  { "type": "string" },
                        "assignee":  { "type": ["string", "null"] },
                        "blockedBy": { "type": ["integer", "null"] },
                        "attachTo":  { "type": ["string", "null"] },
                        "note":      { "type": ["string", "null"] }
                    },
                    "required": ["action"]
                }
            }
        },
        "required": ["asks", "tasks"]
    })
}

/// A task as the model produced it, before validation.
#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawTask {
    #[serde(default)]
    pub action: String,
    #[serde(default)]
    pub subject: Option<String>,
    #[serde(default)]
    pub why: Option<String>,
    #[serde(default)]
    pub done_when: Option<String>,
    #[serde(default)]
    pub assignee: Option<String>,
    #[serde(default)]
    pub blocked_by: Option<i64>,
    #[serde(default)]
    pub attach_to: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(serde::Deserialize)]
struct RawExtraction {
    /// The model's own enumeration of the asks. Never published — see
    /// [`output_schema`] for why it exists.
    #[serde(default)]
    asks: Vec<String>,
    #[serde(default)]
    tasks: Vec<RawTask>,
}

/// Extract `{"tasks": [...]}` from a model reply.
///
/// Tolerates an endpoint that ignored `response_format` and wrapped the JSON in
/// prose or a fenced block — the same tolerance
/// [`crate::relevance::parse_verdict`] needs and for the same reason.
pub fn parse_tasks(reply: &str) -> Result<(Vec<String>, Vec<RawTask>), String> {
    let trimmed = reply.trim();
    if let Ok(parsed) = serde_json::from_str::<RawExtraction>(trimmed) {
        return Ok((parsed.asks, parsed.tasks));
    }
    // Find the outermost `{...}` and try that. A fenced block, a preamble and a
    // trailing apology all reduce to this.
    let start = trimmed.find('{').ok_or_else(|| {
        format!(
            "no JSON object in reply: {}",
            trimmed.chars().take(200).collect::<String>()
        )
    })?;
    let end = trimmed
        .rfind('}')
        .filter(|end| *end > start)
        .ok_or_else(|| {
            format!(
                "JSON object never closes — the reply looks truncated: …{}",
                trimmed.chars().rev().take(80).collect::<String>().chars().rev().collect::<String>()
            )
        })?;
    serde_json::from_str::<RawExtraction>(&trimmed[start..=end])
        .map(|p| (p.asks, p.tasks))
        .map_err(|e| e.to_string())
}

/// Check every field against something the harness can verify, and drop —
/// never repair — a task that fails.
///
/// Validation is deliberately per-task rather than all-or-nothing on this
/// layer: the atomicity the design asks for ("all N or none") belongs to
/// publication, where a partial write is the thing that breaks a replay. Here,
/// a single malformed entry in a list of four must not cost the other three.
pub fn validate(
    raw: Vec<RawTask>,
    input: &ExtractInput,
    known_pubkeys: &HashSet<String>,
) -> Extraction {
    let board_ids: HashSet<&str> = input.board.iter().map(|t| t.id.as_str()).collect();
    let n = raw.len();
    let mut out = Extraction::default();

    for (index, task) in raw.into_iter().enumerate() {
        match task.action.as_str() {
            "create" => {
                let subject = task.subject.unwrap_or_default().trim().to_string();
                if subject.is_empty() {
                    out.dropped.push(Dropped { index, reason: "create with empty subject".into() });
                    continue;
                }
                if subject.chars().count() > MAX_SUBJECT_CHARS {
                    out.dropped.push(Dropped {
                        index,
                        reason: format!(
                            "subject is {} chars, over the {MAX_SUBJECT_CHARS}-char tag limit",
                            subject.chars().count()
                        ),
                    });
                    continue;
                }
                let assignee = match task.assignee.as_deref().map(str::trim) {
                    None | Some("") | Some("null") => None,
                    Some(hex) if is_known_pubkey(hex, known_pubkeys) => Some(hex.to_string()),
                    Some(other) => {
                        // Not a drop: an unassigned task is still the work. An
                        // assignment naming nobody is what reads as unassigned
                        // forever on the board's own filter.
                        warn!(
                            assignee = %other.chars().take(80).collect::<String>(),
                            "task extraction proposed an unknown assignee — creating unassigned"
                        );
                        None
                    }
                };
                let blocked_by = match task.blocked_by {
                    None => None,
                    Some(i) if i < 0 => None,
                    Some(i) => {
                        let i = i as usize;
                        if i >= n {
                            out.dropped.push(Dropped {
                                index,
                                reason: format!("blockedBy {i} is outside this extraction ({n})"),
                            });
                            continue;
                        }
                        if i == index {
                            out.dropped
                                .push(Dropped { index, reason: "blockedBy points at itself".into() });
                            continue;
                        }
                        Some(i)
                    }
                };
                out.tasks.push(TaskAction::Create {
                    subject,
                    why: non_empty_or(task.why, "not stated"),
                    done_when: non_empty_or(task.done_when, "not stated"),
                    assignee,
                    blocked_by,
                });
            }
            "attach" => {
                let attach_to = task.attach_to.unwrap_or_default().trim().to_string();
                if attach_to.is_empty() {
                    out.dropped
                        .push(Dropped { index, reason: "attach with no attachTo".into() });
                    continue;
                }
                // The constraint that makes a hallucinated id fail validation
                // instead of creating a dangling link.
                if !board_ids.contains(attach_to.as_str()) {
                    out.dropped.push(Dropped {
                        index,
                        reason: format!(
                            "attachTo {} is not on the supplied board",
                            attach_to.chars().take(16).collect::<String>()
                        ),
                    });
                    continue;
                }
                out.tasks.push(TaskAction::Attach {
                    attach_to,
                    note: non_empty_or(task.note, "not stated"),
                });
            }
            "none" | "" => {
                // A model that answers the `none` case as a list entry rather
                // than an empty list is not wrong, only verbose.
            }
            other => out.dropped.push(Dropped {
                index,
                reason: format!("unknown action `{}`", other.chars().take(40).collect::<String>()),
            }),
        }
    }
    out
}

fn non_empty_or(value: Option<String>, fallback: &str) -> String {
    match value {
        Some(v) if !v.trim().is_empty() => v.trim().to_string(),
        _ => fallback.to_string(),
    }
}

fn is_known_pubkey(hex: &str, known: &HashSet<String>) -> bool {
    hex.len() == 64
        && hex.chars().all(|c| c.is_ascii_hexdigit())
        && (known.is_empty() || known.contains(&hex.to_ascii_lowercase()))
}

/// Render the input the model reads.
pub fn render_input(input: &ExtractInput) -> String {
    let mut s = String::new();

    if input.board.is_empty() {
        s.push_str("OPEN TASKS: none.\n\n");
    } else {
        s.push_str("OPEN TASKS (the only legal `attachTo` values):\n");
        for t in input.board.iter().take(MAX_BOARD_ENTRIES) {
            let who = t.assignee.as_deref().unwrap_or("unassigned");
            s.push_str(&format!("  {} [{}] {} — {}\n", t.id, t.state, t.subject, who));
        }
        s.push('\n');
    }

    if !input.thread_context.is_empty() {
        s.push_str("THREAD SO FAR (oldest first):\n");
        for entry in input.thread_context.iter().take(MAX_CONTEXT_ENTRIES) {
            let clipped: String = entry.chars().take(MAX_CONTEXT_ENTRY_CHARS).collect();
            s.push_str(&format!("  - {clipped}\n"));
        }
        s.push('\n');
    }

    match &input.message {
        Some(m) => {
            s.push_str(&format!("CHANNEL: {}\n", m.channel));
            s.push_str("THE MESSAGE:\n");
            s.push_str(&m.text.chars().take(MAX_CONTENT_CHARS).collect::<String>());
            s.push('\n');
        }
        None => s.push_str("THE MESSAGE:\n(missing)\n"),
    }
    s
}

/// The extractor's system prompt.
///
/// # The asymmetry leads, because the gate is asymmetric
///
/// `scripts/task-extractor/task-extractor-eval.py` fails a run for a false
/// `none` or an undercount and passes an overcount. A prompt that does not say
/// so optimises for the wrong thing.
///
/// The first version of this text did exactly that. It opened with the
/// board-flooding argument and gave five vivid examples of the `none` case
/// before ever describing `create`, and `gemini-3.8-flash` scored **5/11 with
/// four false `none`s** on the corpus — including `6bfd1e01`, a message that
/// plainly asks for three things. The same model on the same message, given a
/// two-line prompt, returned all three correctly. The model was never the
/// constraint; the ordering of the instructions was.
///
/// # What the corpus says is hard
///
/// - **create vs none.** Four of the eleven readable utterances are status
///   sweeps or process instructions and must produce nothing. The hard case
///   sits in the same frustrated voice and **is** a create: "you should be
///   waking every 10 minutes … work with wren to architecture a robust
///   solution" asked for a mechanism, and that mechanism now exists. So the
///   test is not tone. It is whether something would exist afterwards.
/// - **attach vs none.** "where are we with assessing spark 1.3?" attaches;
///   "where are we at in all our initiatives?" does not. Same sentence shape,
///   different answers, and only the supplied board separates them — which is
///   why [`render_input`] always sends one.
pub const SYSTEM_PROMPT: &str = r#"You read one chat message from the team's owner and decide what work it asks for.

Reply ONLY with JSON. Both fields are required:

  {"asks": ["…", "…"], "tasks": [ … ]}

where each task is one of:

  {"action":"create","subject":"…","why":"…","doneWhen":"…","assignee":null,"blockedBy":null}
  {"action":"attach","attachTo":"<an id copied from OPEN TASKS>","note":"…"}

THE ASYMMETRY — read this before anything else.

A task you invent that nobody needed sits on the board until someone closes it,
which costs one click. A task you fail to extract is never noticed again, and
the work simply does not happen. These are not equally bad. WHEN IN DOUBT,
EXTRACT. Prefer more tasks to fewer, and prefer `create` to an empty list.

HOW TO DO IT.

Step 1. Fill in `asks`: one short string per distinct thing the owner wants,
in the order asked. A single sentence often holds several ("move X, delete Y,
then look at Z" is three). Write them out before you do anything else — you
will emit one entry per ask, so an ask you do not list is work you will lose.
If the message asks for nothing, `asks` is empty.

Step 2. For EACH entry in `asks`, in the same order, emit one entry in `tasks`.
`tasks` has the same length as `asks` unless an ask turns out to be one of the
empty-list cases below. For each one:

  * FIRST look down the OPEN TASKS list and ask "is this ask about one of
    these?" If it is — a status question about it, direction on how to do it,
    a correction to it, or something to add to it — emit `attach` and copy
    that id into `attachTo` exactly. Do NOT create a second task for work the
    board already holds. "I know we already are running a comparison, can we
    add X to that?" is an attach. So is "how is <listed thing> going?" and
    "keep on this". Match on what the work IS, not on shared wording: the
    board's subject was written by someone else and will not use the owner's
    words.

  * ONLY if no open task covers it, emit `create`: something should exist when
    the work is done — a change, a fix, a design, an artifact, an
    investigation with a result, a mechanism, a process that runs. Write a
    `doneWhen` someone else could observe.

Step 3. If the message orders the items ("once all of that is done…", "then",
"after that"), set `blockedBy` on the later entry to the INDEX of the entry it
waits for.

THE EMPTY LIST is only for a message that asks for NO THING TO EXIST. It is a
narrow case, not a default:

  - a status sweep with no single subject ("where are we at on everything?")
  - asking whether people are working, blocked, or stuck
  - challenging an answer just given ("are you sure?")
  - asking someone to go and talk to people, with nothing to build
  - greetings, thanks, agreement, thinking aloud

If you can name one concrete thing that would exist afterwards, it is NOT this
case. A frustrated message that asks for a MECHANISM to be built ("you should
be waking every 10 minutes to catch this — work with X to design a robust
solution") is a `create`: the mechanism is the deliverable. Only a message that
asks someone to go and check on people, leaving nothing behind, is empty.

FIELDS.

  `subject`   a short imperative line, at most 256 characters: what the task is.
  `why`       one line, or "not stated".
  `doneWhen`  the observable result.
  `assignee`  a 64-hex pubkey, or null. A name in prose is NOT a pubkey — use
              null unless you were given the hex.

Count matters as much as the label. A message asking for three things that you
return as one has the label right and the work wrong. The asymmetry applies
here too: IF YOU ARE UNSURE WHETHER TWO CLAUSES ARE ONE TASK OR TWO, EMIT TWO.
Splitting one task in half costs a click. Merging two into one loses work."#;

#[cfg(test)]
mod tests {
    use super::*;

    fn board() -> Vec<BoardTask> {
        vec![
            BoardTask {
                id: "a".repeat(64),
                subject: "Assess Spark 1.3 against Flash".into(),
                state: "open".into(),
                assignee: None,
            },
            BoardTask {
                id: "b".repeat(64),
                subject: "Ship the Desktop Tasks tab".into(),
                state: "open".into(),
                assignee: Some("c".repeat(64)),
            },
        ]
    }

    fn input_with_board() -> ExtractInput {
        ExtractInput {
            message: Some(SourceMessage {
                id: "d".repeat(64),
                channel: "8dd69e3d-8b3c-49fd-ad42-a3e32f495379".into(),
                author: "e".repeat(64),
                text: "where are we with assessing spark 1.3?".into(),
                thread_root: None,
            }),
            thread_context: vec![],
            board: board(),
        }
    }

    fn known() -> HashSet<String> {
        ["c".repeat(64)].into_iter().collect()
    }

    fn raw(json: &str) -> Vec<RawTask> {
        parse_tasks(json).expect("fixture should parse").1
    }

    #[test]
    fn parses_a_bare_object() {
        let tasks = raw(r#"{"asks":["s"],"tasks":[{"action":"create","subject":"s"}]}"#);
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].action, "create");
    }

    #[test]
    fn parses_an_empty_list() {
        assert!(raw(r#"{"tasks":[]}"#).is_empty());
    }

    #[test]
    fn parses_json_wrapped_in_prose_and_a_fence() {
        // An endpoint that ignores `response_format` is the common case on a
        // local engine, and it must not read as a transport failure.
        let tasks = raw("Sure! Here you go:\n```json\n{\"tasks\":[{\"action\":\"attach\",\"attachTo\":\"x\"}]}\n```\nHope that helps.");
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].action, "attach");
    }

    #[test]
    fn a_reply_with_no_json_is_an_error_not_an_empty_extraction() {
        // Silence and "I could not do that" must be distinguishable: an empty
        // list is a decision, a parse failure is not.
        let err = parse_tasks("I'm not sure what you mean.").unwrap_err();
        assert!(err.contains("no JSON object"), "{err}");
    }

    #[test]
    fn a_truncated_reply_says_it_was_truncated() {
        // This is the fault that cost the first two corpus replays. A reply cut
        // off at the token budget is a half-written object, and calling it
        // "malformed" sends the reader after a model bug instead of a budget.
        let err = parse_tasks(r#"{"tasks":[{"action":"create","subject":"half a su"#).unwrap_err();
        assert!(err.contains("truncated"), "{err}");
        assert!(err.contains("half a su"), "the tail is the evidence: {err}");
    }

    #[test]
    fn the_token_budget_leaves_room_for_thinking() {
        // Measured on gemini-3.8-flash against SYSTEM_PROMPT: thinking is spent
        // before a byte of JSON is written, and both come out of `max_tokens`.
        // 1600 truncated 5 of 11 corpus utterances; 4000 truncated 2.
        assert!(
            default_max_tokens() >= 8_000,
            "a thinking model spends the budget before it writes"
        );
    }

    #[test]
    fn retries_are_on_by_default_and_escalate_the_budget() {
        // Three consecutive corpus replays failed on a DIFFERENT utterance each
        // time. A single-shot extractor drops roughly one ask in eight to
        // transient endpoint faults, and a dropped ask is indistinguishable
        // from "no work here".
        assert!(default_attempts() >= 2, "one shot loses ~1 ask in 8 to transients");
        let defaulted: TaskExtractConfig =
            serde_json::from_str(r#"{"endpoint":"http://x/v1","model":"m"}"#).unwrap();
        assert_eq!(defaulted.attempts, default_attempts());
    }

    #[tokio::test]
    async fn a_failing_endpoint_is_asked_exactly_attempts_times_then_reported() {
        // The retry has to be bounded and the give-up has to be an `error`,
        // not an empty verdict. Both halves are load-bearing: unbounded retries
        // stall the turn, and a silent give-up is the bug this module was
        // written to remove.
        let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let bodies: std::sync::Arc<std::sync::Mutex<Vec<serde_json::Value>>> =
            std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen = hits.clone();
        let recorded = bodies.clone();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else { return };
                seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                // Read the request far enough to recover its JSON body: the
                // temperature the retry used is the thing under test.
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                while let Ok(n) = sock.read(&mut chunk).await {
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        let body = &buf[pos + 4..];
                        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(body) {
                            recorded.lock().unwrap().push(v);
                            break;
                        }
                    }
                }
                let body = b"{\"choices\":[{\"finish_reason\":\"length\",\"message\":{}}]}";
                let head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = sock.write_all(head.as_bytes()).await;
                let _ = sock.write_all(body).await;
                let _ = sock.shutdown().await;
            }
        });

        let cfg = TaskExtractConfig {
            endpoint: format!("http://{addr}"),
            model: "m".into(),
            timeout_ms: 5_000,
            max_tokens: 100,
            reasoning_effort: None,
            attempts: 3,
        };
        let extraction = TaskExtractor::new(None, HashSet::new())
            .extract(&cfg, &input_with_board())
            .await;

        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 3, "bounded at `attempts`");
        assert_eq!(bodies.lock().unwrap().len(), 3);
        let temps: Vec<f64> = bodies
            .lock()
            .unwrap()
            .iter()
            .filter_map(|b| b.pointer("/temperature").and_then(|v| v.as_f64()))
            .collect();
        assert_eq!(temps[0], 0.0, "the first ask is greedy");
        assert!(
            temps[1..].iter().all(|t| *t > 0.0),
            "a retry must take a different path through the model: {temps:?}"
        );
        assert!(extraction.tasks.is_empty());
        assert_eq!(extraction.verdict(), Verdict::None { count: 0 });
        let err = extraction.error.expect("a give-up must be an error, not a verdict");
        assert!(err.contains("truncated"), "{err}");
    }

    #[test]
    fn reasoning_effort_is_unset_by_default_because_decomposition_is_thinking() {
        // The tempting default is `low`: it cuts thinking ~5x and stops the
        // truncation that scored as `none`. Measured, it trades one silent
        // failure for another — at `low` the model returned ONE task for a
        // four-ask message and the corpus gate failed; unset, it returned four
        // and the gate passed. Truncation is the retry's job.
        let defaulted: TaskExtractConfig =
            serde_json::from_str(r#"{"endpoint":"http://x/v1","model":"m"}"#).unwrap();
        assert!(defaulted.reasoning_effort.is_none());
        assert_eq!(defaulted.max_tokens, 8_000);
        assert_eq!(defaulted.attempts, 3);
        assert_eq!(defaulted.timeout_ms, 20_000);

        let explicit: TaskExtractConfig = serde_json::from_str(
            r#"{"endpoint":"http://x/v1","model":"m","reasoning_effort":"high"}"#,
        )
        .unwrap();
        assert_eq!(explicit.reasoning_effort.as_deref(), Some("high"));
    }

    #[test]
    fn an_empty_list_is_the_none_verdict() {
        let e = validate(vec![], &input_with_board(), &known());
        assert_eq!(e.verdict(), Verdict::None { count: 0 });
        assert!(e.dropped.is_empty());
    }

    #[test]
    fn counts_creates_not_entries() {
        // 2.1 of the design note: the count is a first-class failure. A
        // four-ask message extracted as one task has the label right and the
        // work wrong, so the reduction must count creates.
        let e = validate(
            raw(r#"{"tasks":[
                {"action":"create","subject":"one"},
                {"action":"create","subject":"two"},
                {"action":"create","subject":"three"}]}"#),
            &input_with_board(),
            &known(),
        );
        assert_eq!(e.verdict(), Verdict::Create { count: 3 });
    }

    #[test]
    fn a_create_beside_an_attach_reduces_to_create() {
        // The create is the work that would otherwise go missing; the gate
        // punishes a false `none`, never a spurious task.
        let e = validate(
            raw(&format!(
                r#"{{"tasks":[
                    {{"action":"attach","attachTo":"{}"}},
                    {{"action":"create","subject":"one"}}]}}"#,
                "a".repeat(64)
            )),
            &input_with_board(),
            &known(),
        );
        assert_eq!(e.verdict(), Verdict::Create { count: 1 });
    }

    #[test]
    fn an_attach_to_an_id_not_on_the_board_is_dropped() {
        // The constraint that turns a hallucinated id into a validation failure
        // rather than a dangling link on the board.
        let e = validate(
            raw(r#"{"tasks":[{"action":"attach","attachTo":"0000000000000000"}]}"#),
            &input_with_board(),
            &known(),
        );
        assert!(e.tasks.is_empty());
        assert_eq!(e.dropped.len(), 1);
        assert!(e.dropped[0].reason.contains("not on the supplied board"), "{:?}", e.dropped);
        assert_eq!(e.verdict(), Verdict::None { count: 0 });
    }

    #[test]
    fn an_attach_to_a_board_id_survives() {
        let e = validate(
            raw(&format!(
                r#"{{"tasks":[{{"action":"attach","attachTo":"{}","note":"asked again"}}]}}"#,
                "a".repeat(64)
            )),
            &input_with_board(),
            &known(),
        );
        assert_eq!(e.verdict(), Verdict::Attach { count: 1 });
        assert!(e.dropped.is_empty());
    }

    #[test]
    fn a_create_with_an_empty_subject_is_dropped() {
        let e = validate(
            raw(r#"{"tasks":[{"action":"create","subject":"   "}]}"#),
            &input_with_board(),
            &known(),
        );
        assert!(e.tasks.is_empty());
        assert!(e.dropped[0].reason.contains("empty subject"));
    }

    #[test]
    fn a_subject_over_the_tag_limit_is_dropped_not_truncated() {
        // A clipped subject reads as a deliberate one. Better to lose the task
        // loudly than to publish a sentence cut mid-word as the title.
        let long = "x".repeat(MAX_SUBJECT_CHARS + 1);
        let e = validate(
            raw(&format!(r#"{{"tasks":[{{"action":"create","subject":"{long}"}}]}}"#)),
            &input_with_board(),
            &known(),
        );
        assert!(e.tasks.is_empty());
        assert!(e.dropped[0].reason.contains("over the"), "{:?}", e.dropped);
    }

    #[test]
    fn blocked_by_keeps_an_ordering_and_rejects_a_bad_index() {
        let e = validate(
            raw(r#"{"tasks":[
                {"action":"create","subject":"first"},
                {"action":"create","subject":"second","blockedBy":0}]}"#),
            &input_with_board(),
            &known(),
        );
        assert_eq!(e.tasks.len(), 2);
        assert!(matches!(&e.tasks[1], TaskAction::Create { blocked_by: Some(0), .. }));

        let bad = validate(
            raw(r#"{"tasks":[{"action":"create","subject":"only","blockedBy":7}]}"#),
            &input_with_board(),
            &known(),
        );
        assert!(bad.tasks.is_empty());
        assert!(bad.dropped[0].reason.contains("outside this extraction"));

        let selfref = validate(
            raw(r#"{"tasks":[{"action":"create","subject":"only","blockedBy":0}]}"#),
            &input_with_board(),
            &known(),
        );
        assert!(selfref.tasks.is_empty());
        assert!(selfref.dropped[0].reason.contains("itself"));
    }

    #[test]
    fn an_unknown_assignee_creates_unassigned_rather_than_dropping_the_task() {
        // `buzz issues assign` with a pubkey nobody holds is a signed no-op
        // that reads as unassigned forever. Losing the assignment is survivable;
        // losing the task is the failure this project exists to remove.
        let e = validate(
            raw(&format!(
                r#"{{"tasks":[{{"action":"create","subject":"s","assignee":"{}"}}]}}"#,
                "f".repeat(64)
            )),
            &input_with_board(),
            &known(),
        );
        assert_eq!(e.tasks.len(), 1);
        assert!(matches!(&e.tasks[0], TaskAction::Create { assignee: None, .. }));
        assert!(e.dropped.is_empty());
    }

    #[test]
    fn a_known_assignee_survives() {
        let e = validate(
            raw(&format!(
                r#"{{"tasks":[{{"action":"create","subject":"s","assignee":"{}"}}]}}"#,
                "c".repeat(64)
            )),
            &input_with_board(),
            &known(),
        );
        assert!(matches!(&e.tasks[0], TaskAction::Create { assignee: Some(_), .. }));
    }

    #[test]
    fn a_malformed_entry_does_not_cost_its_siblings() {
        // Per-task validation, not all-or-nothing: atomicity belongs to
        // publication, where a partial write breaks a replay.
        let e = validate(
            raw(r#"{"tasks":[
                {"action":"create","subject":"good"},
                {"action":"attach","attachTo":"nope"},
                {"action":"create","subject":"also good"}]}"#),
            &input_with_board(),
            &known(),
        );
        assert_eq!(e.tasks.len(), 2);
        assert_eq!(e.dropped.len(), 1);
        assert_eq!(e.verdict(), Verdict::Create { count: 2 });
    }

    #[test]
    fn an_unknown_action_is_dropped_and_named() {
        let e = validate(
            raw(r#"{"tasks":[{"action":"delete","subject":"s"}]}"#),
            &input_with_board(),
            &known(),
        );
        assert!(e.tasks.is_empty());
        assert!(e.dropped[0].reason.contains("unknown action"));
    }

    #[test]
    fn rendered_input_offers_the_board_as_the_attach_vocabulary() {
        // `attach` is undecidable without it: "where are we with spark 1.3?"
        // and "where are we with everything?" are the same sentence shape and
        // different answers, and only the board tells them apart.
        let rendered = render_input(&input_with_board());
        assert!(rendered.contains("OPEN TASKS"));
        assert!(rendered.contains("Assess Spark 1.3 against Flash"));
        assert!(rendered.contains(&"a".repeat(64)));
        assert!(rendered.contains("where are we with assessing spark 1.3?"));
    }

    #[test]
    fn rendered_input_says_so_when_the_board_is_empty() {
        let mut input = input_with_board();
        input.board.clear();
        assert!(render_input(&input).contains("OPEN TASKS: none."));
    }

    #[test]
    fn rendered_input_caps_the_board_the_context_and_the_message() {
        let mut input = input_with_board();
        input.board = (0..MAX_BOARD_ENTRIES + 10)
            .map(|i| BoardTask {
                id: format!("{i:064}"),
                subject: format!("task {i}"),
                state: "open".into(),
                assignee: None,
            })
            .collect();
        input.thread_context = (0..MAX_CONTEXT_ENTRIES + 5).map(|i| format!("entry {i}")).collect();
        input.message.as_mut().unwrap().text = "z".repeat(MAX_CONTENT_CHARS + 500);

        let rendered = render_input(&input);
        assert!(rendered.contains(&format!("{:064}", MAX_BOARD_ENTRIES - 1)));
        assert!(!rendered.contains(&format!("{:064}", MAX_BOARD_ENTRIES)));
        assert!(rendered.contains(&format!("entry {}", MAX_CONTEXT_ENTRIES - 1)));
        assert!(!rendered.contains(&format!("entry {}", MAX_CONTEXT_ENTRIES)));
        assert_eq!(rendered.matches('z').count(), MAX_CONTENT_CHARS);
    }

    #[test]
    fn the_prompt_states_the_asymmetry_the_gate_scores() {
        // Measured, not assumed. The first version of this prompt buried the
        // asymmetry under a long list of `none` examples and scored 5/11 with
        // four false `none`s; the same model, same corpus, answered correctly
        // once the asymmetry led. A prompt that loses this clause fails the
        // gate rather than merely scoring worse, so bind it.
        assert!(SYSTEM_PROMPT.contains("WHEN IN DOUBT"));
        assert!(SYSTEM_PROMPT.contains("EXTRACT"));
        assert!(SYSTEM_PROMPT.contains("never noticed again"));
        assert!(SYSTEM_PROMPT.contains("narrow case, not a default"));
    }

    #[test]
    fn the_prompt_teaches_the_three_moves_and_the_ordering() {
        assert!(SYSTEM_PROMPT.contains("doneWhen"));
        assert!(SYSTEM_PROMPT.contains("blockedBy"));
        // attach is decidable only against the supplied board.
        assert!(SYSTEM_PROMPT.contains("copied from OPEN TASKS"));
        assert!(SYSTEM_PROMPT.contains("no open task covers it"));
        // The count is a first-class failure, not a detail.
        assert!(SYSTEM_PROMPT.contains("Count matters"));
        // The asymmetry has to reach the count, not only the action: an
        // undercount fails the gate and an overcount passes it.
        assert!(SYSTEM_PROMPT.contains("EMIT TWO"));
        // Enumeration is an output field, not an instruction the model may
        // skip; and the board is consulted BEFORE a create, not after.
        assert!(SYSTEM_PROMPT.contains("Fill in `asks`"));
        assert!(SYSTEM_PROMPT.contains("ONLY if no open task covers it"));
    }

    #[test]
    fn a_failure_is_not_an_empty_decision() {
        // Both publish nothing, and that is why they have to be readable apart.
        // The first corpus replay scored four transport failures as `none`
        // verdicts because this distinction did not exist.
        let decided = validate(vec![], &input_with_board(), &known());
        assert_eq!(decided.verdict(), Verdict::None { count: 0 });
        assert!(decided.error.is_none());

        let failed = Extraction::failed("504: gateway timeout");
        assert_eq!(failed.verdict(), Verdict::None { count: 0 });
        assert_eq!(failed.error.as_deref(), Some("504: gateway timeout"));
        assert!(failed.tasks.is_empty());
    }

    #[test]
    fn the_schema_forbids_an_action_outside_create_and_attach() {
        let schema = output_schema();
        let enumerated = schema
            .pointer("/properties/tasks/items/properties/action/enum")
            .and_then(|v| v.as_array())
            .expect("action should be an enum");
        assert_eq!(enumerated.len(), 2);
        assert!(enumerated.iter().any(|v| v == "create"));
        assert!(enumerated.iter().any(|v| v == "attach"));
    }
}
