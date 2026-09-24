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
//! # One record per ask
//!
//! One message produces a *list*, and the list is of **asks**, not of tasks.
//! Each record carries the ask verbatim and its own disposition. That shape is
//! the result of three measured failures rather than a preference — see
//! [`output_schema`] for what each of them was.
//!
//! # Fail open, and fail quiet
//!
//! Like [`crate::relevance`], this is not a security boundary. Every failure
//! path — timeout, transport error, unparseable reply, a record that fails
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

/// Cap on records accepted from one reply, so a runaway array cannot publish a
/// hundred issues.
const MAX_ITEMS: usize = 32;

/// Cap on the `ask` echoed back in a record.
const MAX_ASK_CHARS: usize = 300;

/// Cap on `why`, `doneWhen`, `note` and `reason`.
///
/// Each is one line by contract. The cap is what stops a decoder that has
/// started repeating itself from spending the whole budget doing so.
const MAX_LINE_CHARS: usize = 300;

/// Configuration for the extractor's model call.
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
    /// Measured on `gemini-3.8-flash`: at 1600 the reply came back truncated
    /// mid-object on 5 of the 11 corpus utterances — which parses as a
    /// transport failure, not as a short answer. Leave headroom.
    #[serde(default = "default_max_tokens")]
    pub max_tokens: u32,
    /// OpenAI-style `reasoning_effort`, sent only when set.
    ///
    /// **Unset by default, and that is a measured choice against an obvious
    /// one.** Constraining it to `low` cuts thinking ~5× on `gemini-3.8-flash`
    /// (619 tokens → 126 on the corpus's hardest utterance), which looks like a
    /// pure win for latency and truncation. It is not: decomposition is the
    /// thinking. At `low` the same model returned **one** record for a message
    /// asking four, and mistook two board-status questions for new work.
    ///
    /// Truncation is the right thing to fix with [`Self::attempts`] and a
    /// budget that doubles, not by taking away the model's ability to count.
    #[serde(default)]
    pub reasoning_effort: Option<String>,
    /// How many times to ask before giving up.
    ///
    /// Not politeness — measured necessity. Three consecutive replays of the
    /// eleven-utterance corpus failed on `6bfd1e01`, then `17ced753`, then
    /// `46c1401d` and `5872666e`: **a different utterance every time**, at
    /// roughly one or two calls in eleven. Truncation and Gemini's `RECITATION`
    /// content filter are both transient and neither correlates with the
    /// message. A single-shot extractor drops about one ask in eight for no
    /// reason anyone could name afterwards.
    ///
    /// Each retry doubles [`Self::max_tokens`], which is free when the failure
    /// was not a truncation and is the fix when it was.
    #[serde(default = "default_attempts")]
    pub attempts: u32,
    /// Sampling temperature for the first attempt.
    ///
    /// Greedy by default, which is what production wants. **A sweep at 0.0 is
    /// one draw plus endpoint noise, not N samples** — eight greedy decodes of
    /// a byte-identical prompt tell you the mode and nothing about the
    /// distribution around it. Comparing two prompts needs this raised; see
    /// `scripts/task-extractor/README.md`.
    #[serde(default)]
    pub temperature: f64,
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

/// One extracted action, with the ask it came from.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub enum TaskAction {
    Create {
        /// The owner's own words for this ask. Published in the issue body, so
        /// the provenance of a task is visible on the board rather than only in
        /// a log.
        ask: String,
        subject: String,
        why: String,
        done_when: String,
        assignee: Option<String>,
        /// Index into the surviving task list, not into the model's records.
        blocked_by: Option<usize>,
    },
    Attach {
        ask: String,
        /// Must be an id from the supplied board.
        attach_to: String,
        note: String,
    },
}

impl TaskAction {
    /// The owner's own words for this ask. Publication puts it in the issue
    /// body so a task's provenance is readable on the board, not only in a log.
    pub fn ask(&self) -> &str {
        match self {
            TaskAction::Create { ask, .. } | TaskAction::Attach { ask, .. } => ask,
        }
    }
}

/// The reduction the eval scores.
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

/// A record that did not survive validation, kept so the drop is loggable.
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
    /// Every ask the model enumerated, including the ones it dispositioned
    /// `none`. Diagnostic only — never published.
    pub asks: Vec<String>,
    /// Indices of `create` records that arrived with no observable `doneWhen`.
    ///
    /// The schema requires the field, so this should stay empty; it is here
    /// because the field being *present and vacuous* is exactly what a
    /// degrading model produces, and `non_empty_or(…, "not stated")` used to
    /// hide it. A create nobody can close is a defect even when the gate
    /// counts it as work extracted.
    pub thin: Vec<usize>,
    /// The raw `message.content` of the reply that produced this extraction,
    /// and its `finish_reason`. Kept for the replay's `--detail`: key order
    /// shows what the model wrote first, and an unknown key shows work nested
    /// where the parser cannot see it.
    pub raw_reply: Option<String>,
    pub finish_reason: Option<String>,
}

impl Extraction {
    /// An extraction that never got an answer.
    pub fn failed(reason: impl Into<String>) -> Self {
        Self { error: Some(reason.into()), ..Default::default() }
    }

    /// Normalised subjects of the `create` tasks, deduplicated.
    ///
    /// A model under prompt pressure repeats itself: two of the anti-merge
    /// sweep's `create` rows were the same subject twice, and a verdict that
    /// counts array entries reads that as decomposition. Count what is
    /// distinct.
    pub fn distinct_subjects(&self) -> Vec<String> {
        let mut seen = Vec::new();
        for t in &self.tasks {
            if let TaskAction::Create { subject, .. } = t {
                let norm = subject.trim().to_lowercase();
                if !norm.is_empty() && !seen.contains(&norm) {
                    seen.push(norm);
                }
            }
        }
        seen
    }

    /// How many `create` entries were a repeat of a subject already emitted.
    pub fn duplicate_subjects(&self) -> usize {
        let creates = self
            .tasks
            .iter()
            .filter(|t| matches!(t, TaskAction::Create { .. }))
            .count();
        creates.saturating_sub(self.distinct_subjects().len())
    }

    /// Collapse to the eval's `(action, count)` shape.
    pub fn verdict(&self) -> Verdict {
        let distinct = self.distinct_subjects().len();
        if distinct > 0 {
            return Verdict::Create { count: distinct };
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
    /// empty [`Extraction`] carrying `error`, because capture is important and
    /// blocking a reply on it is not.
    pub async fn extract(&self, cfg: &TaskExtractConfig, input: &ExtractInput) -> Extraction {
        let attempts = cfg.attempts.max(1);
        let mut budget = cfg.max_tokens;
        let mut last_error = String::from("no attempt was made");
        let mut last_reply = String::new();
        // Only used when every attempt dropped something: better a partial
        // extraction than none.
        let mut best: Option<Extraction> = None;

        for attempt in 1..=attempts {
            let try_cfg = TaskExtractConfig { max_tokens: budget, ..cfg.clone() };
            // A retry must take a DIFFERENT path through the model or it is not
            // a retry at all. Gemini's `RECITATION` content filter is a
            // property of the sampled continuation, so identical greedy calls
            // are blocked identically — measured on `46c1401d`, which lost all
            // three attempts at temperature 0 and answered on the first
            // non-greedy one.
            let temperature = if attempt == 1 { cfg.temperature } else { cfg.temperature.max(0.4) };
            match self.ask(&try_cfg, input, temperature).await {
                Ok((raw_reply, finish_reason, items)) => {
                    let mut extraction = validate(items, input, &self.known_pubkeys);
                    extraction.raw_reply = Some(raw_reply);
                    extraction.finish_reason = finish_reason;
                    // A dropped record is a lost ask, which is the failure this
                    // module exists to remove — so it is retryable, exactly
                    // like a transport error. It is not hypothetical: the first
                    // run of the per-ask schema emitted `attach` with no
                    // `attachTo` on all three attach rows, and each one landed
                    // as a `none` verdict. `oneOf` should make that
                    // unreachable; this is the belt for an endpoint that only
                    // honours JSON mode.
                    if !extraction.dropped.is_empty() && attempt < attempts {
                        warn!(
                            attempt,
                            of = attempts,
                            dropped = extraction.dropped.len(),
                            first = %extraction.dropped[0].reason,
                            "task extraction dropped a record — asking again"
                        );
                        last_error = format!(
                            "{} record(s) failed validation, last attempt: {}",
                            extraction.dropped.len(),
                            extraction.dropped[0].reason
                        );
                        best = Some(extraction);
                        continue;
                    }
                    for d in &extraction.dropped {
                        warn!(
                            index = d.index,
                            reason = %d.reason,
                            "task extraction dropped a record that failed validation"
                        );
                    }
                    for i in &extraction.thin {
                        warn!(index = i, "task extraction produced a create with no doneWhen");
                    }
                    debug!(
                        tasks = extraction.tasks.len(),
                        distinct = extraction.distinct_subjects().len(),
                        duplicates = extraction.duplicate_subjects(),
                        dropped = extraction.dropped.len(),
                        asks = extraction.asks.len(),
                        "task extraction complete"
                    );
                    return extraction;
                }
                Err(ParseFailure { error, reply }) => {
                    warn!(
                        attempt,
                        of = attempts,
                        budget,
                        error = %error,
                        "task extraction attempt failed"
                    );
                    last_error = error;
                    last_reply = reply;
                    budget = budget.saturating_mul(2);
                }
            }
        }
        if let Some(mut partial) = best {
            warn!(
                dropped = partial.dropped.len(),
                "every attempt dropped a record — publishing the best partial extraction"
            );
            partial.error = None;
            return partial;
        }
        warn!(error = %last_error, "task extraction failed — turn proceeds with no extraction");
        let mut failed = Extraction::failed(last_error);
        if !last_reply.is_empty() {
            failed.raw_reply = Some(last_reply);
        }
        failed
    }

    async fn ask(
        &self,
        cfg: &TaskExtractConfig,
        input: &ExtractInput,
        temperature: f64,
    ) -> Result<(String, Option<String>, Vec<RawItem>), ParseFailure> {
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
                "json_schema": { "name": "extraction", "schema": output_schema(&input.board) }
            }
        });
        if let (Some(effort), Some(map)) = (&cfg.reasoning_effort, body.as_object_mut()) {
            map.insert(
                "reasoning_effort".to_string(),
                serde_json::Value::String(effort.clone()),
            );
        }

        let (reply, finish) = self
            .post(cfg, body)
            .await
            .map_err(|e| ParseFailure { error: e, reply: String::new() })?;
        // A parse failure is exactly when the raw text is worth having, so it
        // rides out with the error rather than being lost to `?`. Without this
        // a schema/struct field-name mismatch reports `rawReply: null`, which
        // is the one row where the bytes would have named the bug instantly.
        let items = parse_items(&reply).map_err(|e| ParseFailure { error: e, reply: reply.clone() })?;
        Ok((reply, finish, items))
    }

    /// POST one chat completion and return `choices[0].message.content` with
    /// its `finish_reason`.
    ///
    /// Every failure mode is named for what it actually is — a status, a
    /// truncation, a content filter — because all three arrive downstream as
    /// "no tasks" and are otherwise indistinguishable from a verdict.
    async fn post(
        &self,
        cfg: &TaskExtractConfig,
        body: serde_json::Value,
    ) -> Result<(String, Option<String>), String> {
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
        // half-written JSON object, and the parser can only report that as
        // malformed — which sends whoever reads the log hunting a model bug
        // instead of raising a budget. Name the real cause here.
        let finish = json
            .pointer("/choices/0/finish_reason")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if finish == "length" {
            return Err(format!(
                "reply truncated at the {}-token budget (finish_reason=length); \
                 a thinking model spends this budget before it writes",
                cfg.max_tokens
            ));
        }
        json.pointer("/choices/0/message/content")
            .and_then(|v| v.as_str())
            .map(|c| (c.to_string(), Some(finish.clone())))
            .ok_or_else(|| {
                format!("no choices[0].message.content in response (finish_reason={finish})")
            })
    }
}

/// The JSON schema handed to the endpoint for constrained decoding.
///
/// # Why one array of per-ask records
///
/// The shape is the conclusion of three measured failures, all on
/// `gemini-3.8-flash`, all recorded in
/// [buzz#85](https://github.com/aitaco-llc/buzz/pull/85):
///
/// 1. Two independent arrays — `asks[]` then `tasks[]` — with a sentence asking
///    for their lengths to match. The model enumerated four asks correctly and
///    emitted **one** task, seven runs of seven, `dropped` empty every time. It
///    was not merging: it wrote the first ask's task and closed the array.
/// 2. Pushing that sentence harder ("THESE ARE THE SAME NUMBER … never
///    combine") made the JSON thinner everywhere instead: `doneWhen` absent
///    went from 30% of `create` records to 85%, and two rows repeated a subject
///    verbatim, which a verdict counting array entries reads as decomposition.
/// 3. Splitting enumeration into its own call fixed the enumeration and broke
///    the judgement — handed a list and told to emit one entry per ask, the
///    classifier lost `none` and `attach` (`2279229f`, a message that says
///    outright "add Luna to that", went from 8/8 attach to 2/5).
///
/// One array removes the failure mode rather than arguing with it. There is no
/// second array whose `]` is a fresh decision: once the decoder has written
/// four `ask` strings it has committed to four objects, and continuing a
/// homogeneous array is its prior rather than a choice. `none` survives as a
/// per-ask disposition, so the judgement the model already makes well is
/// untouched. A skeletal record becomes a schema violation — and therefore a
/// retry — instead of a quiet undercount.
///
/// # What it cost, measured over four 8-replay sweeps
///
/// The schema does what prose could not, and it is not free:
///
/// | | accuracy | `attach` | gate |
/// | --- | ---: | ---: | ---: |
/// | two arrays + prose count rule | **93%** | **23/24** | 3/8 |
/// | per-ask records (this) | 74% | 3/24 | **8/8** |
/// | + attach-first prose | 77% | 6/24 | 7/8 |
/// | + a required "why no open task covers this" field | 76% | 3/24 | 6/8 |
///
/// Decomposition is solved: the two utterances that held the gate at 3 of 8
/// went to 7–8 of 8 and stayed there. `attach` broke, and three separate
/// attempts to talk it back — a board-first rule, worked examples, and a field
/// the model had to fill in to justify creating — recovered at most a quarter
/// of it.
///
/// The likely reason, stated so it can be disproved: a per-ask record is a
/// self-contained unit, and a self-contained ask has no reason to be about
/// something on a board it was not asked to consult. The old shape let the
/// model weigh the whole message against the board before committing to
/// anything. **A create where an attach belonged is a duplicate**, which is
/// the board-flooding the design note warns about — so this is a real trade,
/// not a tuning failure, and it is the open question on this module.
///
/// **The obvious schema lever was tried and it is not the answer.** Making
/// `attachTo` an `enum` of the actual open-task ids — so attaching is a choice
/// the decoder can already see and a hallucinated id is unreachable — left
/// `attach` at 4/24 against 6/24 for prose alone, with `2279229f` at 0/8 even
/// though that message says outright "I know we already are running a
/// comparison. Can we just add in Luna to that?". Four interventions now:
///
/// | | accuracy | `attach` | decomposition | gate |
/// | --- | ---: | ---: | ---: | ---: |
/// | two arrays + prose count rule | **93%** | **23/24** | 11/15 | 3/8 |
/// | per-ask records | 74% | 3/24 | **14/16** | **8/8** |
/// | + attach-first prose | 77% | 6/24 | **14/16** | 7/8 |
/// | + `attachTo` enum (this) | 75% | 4/24 | **14/16** | **8/8** |
///
/// So the constraint was never the barrier — the judgement is. Asked about one
/// isolated ask, the model does not recognise "where are we with spark 1.3?"
/// as being about a board row someone else titled "Assess Spark 1.3 against
/// Flash", and making the answer free to express does not make it visible.
///
/// The enum stays regardless of the score: it makes a dangling `attachTo`
/// structurally impossible rather than rejected after the fact, which is worth
/// having on its own.
///
/// What is left to try is a second question rather than a better constraint:
/// keep this schema for decomposition, then ask once per proposed `create`
/// whether any open task already covers *that subject*, with only the subject
/// and the board in front of it. One extra call per create, and it is the
/// question the per-ask framing cannot hold.
///
/// `additionalProperties: false` is not tidiness. A model that expresses "then
/// once all of that is done" as a nested `steps` key inside the first record
/// produces exactly the one-task reading observed in (1), and nothing in the
/// saved replays could rule it out because the raw text was not kept. Now it is
/// a parse error, and [`Extraction::raw_reply`] keeps the evidence either way.
pub fn output_schema(board: &[BoardTask]) -> serde_json::Value {
    // Bounded free text. Not tidiness: at temperature 0 with an unbounded
    // `why`, the model fell into a repetition loop — "properly cleanly fast
    // well nicely reliably" for hundreds of tokens — on the first corpus
    // utterance, and every `doneWhen` after it went unwritten because the
    // budget was gone. A field the decoder must close is a field that cannot
    // run away.
    let short = |max: u32| serde_json::json!({ "type": "string", "maxLength": max });

    // One shape per disposition, each pinning its own required fields. This is
    // what makes `attach` mean something: the first run of the per-ask schema
    // emitted `{"disposition":"attach","subject":"","note":"…"}` with no
    // `attachTo` at all, on all three attach rows, because the flat schema only
    // required `ask` and `disposition`. Verified honoured by Google's
    // OpenAI-compatible endpoint before being relied on.
    let create = serde_json::json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "ask":         short(MAX_ASK_CHARS as u32),
            "disposition": { "type": "string", "enum": ["create"] },
            "subject":     short(MAX_SUBJECT_CHARS as u32),
            "why":         short(MAX_LINE_CHARS as u32),
            "doneWhen":    short(MAX_LINE_CHARS as u32),
            "assignee":    { "type": ["string", "null"] },
            "blockedBy":   { "type": ["integer", "null"] }
        },
        "required": ["ask", "disposition", "subject", "doneWhen"]
    });
    // `attachTo` is an enum of the ids actually on the board, not a free
    // string. Three prose attempts to make the model consult the board before
    // creating recovered at most a quarter of `attach`; this makes attaching a
    // choice the decoder can already see, where creating still costs a fresh
    // `subject` and `doneWhen`. It also makes a hallucinated id unreachable
    // rather than merely rejected after the fact.
    let board_ids: Vec<&str> = board.iter().map(|t| t.id.as_str()).take(MAX_BOARD_ENTRIES).collect();
    let attach = serde_json::json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "ask":         short(MAX_ASK_CHARS as u32),
            "disposition": { "type": "string", "enum": ["attach"] },
            "attachTo":    { "type": "string", "enum": board_ids },
            "note":        short(MAX_LINE_CHARS as u32)
        },
        "required": ["ask", "disposition", "attachTo"]
    });
    let none = serde_json::json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "ask":         short(MAX_ASK_CHARS as u32),
            "disposition": { "type": "string", "enum": ["none"] },
            "reason":      short(MAX_LINE_CHARS as u32)
        },
        "required": ["ask", "disposition"]
    });

    // With nothing on the board there is nothing to attach to, so the shape is
    // not offered at all. An enum with no members is not a legal schema, and an
    // attach the harness would have to drop is worse than one the model could
    // never propose.
    let shapes = if board_ids.is_empty() {
        vec![create, none]
    } else {
        vec![create, attach, none]
    };

    serde_json::json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "items": {
                "type": "array",
                "items": { "oneOf": shapes }
            }
        },
        "required": ["items"]
    })
}

/// A failed attempt, carrying the bytes that failed.
struct ParseFailure {
    error: String,
    reply: String,
}

/// One record as the model produced it, before validation.
///
/// `deny_unknown_fields` is deliberate and pairs with
/// `additionalProperties: false` in [`output_schema`]: work the model nested
/// under a key the harness does not know about must be a loud parse failure and
/// a retry, never a silently smaller task list.
#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RawItem {
    #[serde(default)]
    pub ask: String,
    #[serde(default)]
    pub disposition: String,
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
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct RawExtraction {
    #[serde(default)]
    items: Vec<RawItem>,
}

/// Extract `{"items": [...]}` from a model reply.
///
/// Tolerates an endpoint that ignored `response_format` and wrapped the JSON in
/// prose or a fenced block — the same tolerance
/// [`crate::relevance::parse_verdict`] needs and for the same reason.
pub fn parse_items(reply: &str) -> Result<Vec<RawItem>, String> {
    let trimmed = reply.trim();
    if let Ok(parsed) = serde_json::from_str::<RawExtraction>(trimmed) {
        return Ok(parsed.items);
    }
    let start = trimmed.find('{').ok_or_else(|| {
        format!(
            "no JSON object in reply: {}",
            trimmed.chars().take(200).collect::<String>()
        )
    })?;
    let end = trimmed.rfind('}').filter(|end| *end > start).ok_or_else(|| {
        let tail: String = trimmed.chars().rev().take(80).collect();
        format!(
            "JSON object never closes — the reply looks truncated: …{}",
            tail.chars().rev().collect::<String>()
        )
    })?;
    serde_json::from_str::<RawExtraction>(&trimmed[start..=end])
        .map(|p| p.items)
        .map_err(|e| e.to_string())
}

/// Check every field against something the harness can verify, and drop —
/// never repair — a record that fails.
///
/// Validation is per-record rather than all-or-nothing on this layer: the
/// atomicity the design asks for ("all N or none") belongs to publication,
/// where a partial write is the thing that breaks a replay. Here, a single
/// malformed entry in a list of four must not cost the other three.
pub fn validate(
    raw: Vec<RawItem>,
    input: &ExtractInput,
    known_pubkeys: &HashSet<String>,
) -> Extraction {
    let board_ids: HashSet<&str> = input.board.iter().map(|t| t.id.as_str()).collect();
    let raw: Vec<RawItem> = raw.into_iter().take(MAX_ITEMS).collect();
    let n = raw.len();
    let mut out = Extraction::default();
    // `blockedBy` indexes the model's records; the published tasks are a subset
    // of them, so the link has to be remapped once the drops are known.
    let mut record_to_task: Vec<Option<usize>> = vec![None; n];
    let mut pending_blocks: Vec<(usize, usize)> = Vec::new();

    for (index, item) in raw.into_iter().enumerate() {
        out.asks.push(item.ask.trim().to_string());
        match item.disposition.as_str() {
            "create" => {
                let subject = item.subject.unwrap_or_default().trim().to_string();
                if subject.is_empty() {
                    out.dropped
                        .push(Dropped { index, reason: "create with empty subject".into() });
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
                let assignee = match item.assignee.as_deref().map(str::trim) {
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
                let done_when_raw = item.done_when.clone().unwrap_or_default();
                let observable = !done_when_raw.trim().is_empty()
                    && !done_when_raw.trim().eq_ignore_ascii_case("not stated");
                let task_index = out.tasks.len();
                if !observable {
                    out.thin.push(task_index);
                }
                match item.blocked_by {
                    Some(i) if i >= 0 && (i as usize) < n && (i as usize) != index => {
                        pending_blocks.push((task_index, i as usize));
                    }
                    Some(i) if i >= 0 => {
                        // Out of range or self-referential: keep the task, lose
                        // the link. The ordering is worth less than the work.
                        warn!(blocked_by = i, index, "blockedBy is not a usable index — dropping the link only");
                    }
                    _ => {}
                }
                record_to_task[index] = Some(task_index);
                out.tasks.push(TaskAction::Create {
                    ask: item.ask.trim().to_string(),
                    subject,
                    why: non_empty_or(item.why, "not stated"),
                    done_when: non_empty_or(item.done_when, "not stated"),
                    assignee,
                    blocked_by: None,
                });
            }
            "attach" => {
                let attach_to = item.attach_to.unwrap_or_default().trim().to_string();
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
                // Two records pointing at the same board item are one link.
                if out.tasks.iter().any(|t| {
                    matches!(t, TaskAction::Attach { attach_to: existing, .. } if existing == &attach_to)
                }) {
                    debug!(%attach_to, "second attach to the same board item — collapsed");
                    continue;
                }
                record_to_task[index] = Some(out.tasks.len());
                out.tasks.push(TaskAction::Attach {
                    ask: item.ask.trim().to_string(),
                    attach_to,
                    note: non_empty_or(item.note, "not stated"),
                });
            }
            "none" | "" => {
                // A per-ask `none` is a first-class verdict, not a failure: it
                // is how a message that asks three things and needs two tasks
                // stays honest about the third.
            }
            other => out.dropped.push(Dropped {
                index,
                reason: format!("unknown disposition `{}`", other.chars().take(40).collect::<String>()),
            }),
        }
    }

    for (task_index, record_index) in pending_blocks {
        if let Some(Some(target)) = record_to_task.get(record_index).copied() {
            if target != task_index {
                if let Some(TaskAction::Create { blocked_by, .. }) = out.tasks.get_mut(task_index) {
                    *blocked_by = Some(target);
                }
            }
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
/// # Shorter on purpose
///
/// This text is deliberately smaller than the version it replaces. The count
/// rule and the closing "go back and split them" self-check are gone, because
/// the schema in [`output_schema`] now carries them — and because prose asking
/// the model to re-check its own output is the change that measurably degraded
/// it. Under `response_format` there is no going back and no scratchpad: the
/// check runs in thinking, and the visible JSON gets terser. `doneWhen` absent
/// went from 30% of `create` records to 85% on that edit alone.
///
/// On this stack a rule binds as **a field the model must write** or **a
/// constraint the decoder enforces**, not as an instruction it is asked to
/// obey. What is left here is judgement, which is the part prose is for.
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

Reply ONLY with JSON: {"items": [ … ]}.

`items` is one record per distinct thing the message asks for, in the order
asked. Each record repeats the ask in `ask` and gives it a `disposition`:

  {"ask":"…","disposition":"create","subject":"…","why":"…","doneWhen":"…","assignee":null,"blockedBy":null}
  {"ask":"…","disposition":"attach","attachTo":"<an id copied from OPEN TASKS>","note":"…"}
  {"ask":"…","disposition":"none","reason":"…"}

THE ASYMMETRY — read this before anything else.

A task you invent that nobody needed sits on the board until someone closes it,
which costs one click. A task you fail to extract is never noticed again, and
the work simply does not happen. These are not equally bad. WHEN IN DOUBT,
EXTRACT. Prefer more records to fewer, and prefer `create` to `none`.

That does NOT make `create` the safe answer against `attach`. A second task for
work the board already holds is not a harmless extra — it is a duplicate, and
two rows for one job is how a board becomes unreadable. The owner asks about
the same work again and again; that is the normal case, not the exception.

A single sentence often holds several asks — "move X, get rid of Y, evict Z,
and then once that is done look at W" is FOUR. Write a record for each.

CHOOSING A DISPOSITION. For every ask, look down the OPEN TASKS list FIRST.

  * `attach` — an open task already covers this ask. Copy its id into
    `attachTo` exactly. Use this for a status question about a listed item,
    direction on how to do it, a correction, or something to add to it:
      - "where are we with <listed thing>?"          -> attach
      - "keep on this", "let's make sure we …"       -> attach to what is open
      - "I know we already are running a comparison, can we add X to that?"
        -> attach; the owner has TOLD you it exists
    Match on what the work IS, not on shared wording. The board's subject was
    written by someone else and will not use the owner's words — "Assess Spark
    1.3 against Flash" is the same work as "where are we with spark 1.3?" and
    as "add Luna to that comparison".

  * `create` — you looked, and no open task covers it, and something should
    exist when the work is done: a change, a fix, a design, an artifact, an investigation with a
    result, a mechanism, a process that runs. `doneWhen` must be an observable
    result someone else could agree had happened.

  * `none` — this ask wants an ACTIVITY that leaves nothing behind, or wants
    nothing at all:
      - a status sweep with no single subject ("where are we at on everything?",
        "check in with all the engineers and push us forward")
      - asking whether people are working, blocked, or stuck
      - challenging an answer just given ("are you sure?")
      - an instruction about how to work, with no thing to build
      - greetings, thanks, agreement, thinking aloud
    These produce tasks whose doneWhen is unwritable, and the same person asks
    them again every day. That floods the board and buries the real work.

The line between `create` and `none` is NOT tone. A frustrated message that
asks for a MECHANISM to be built ("you should be waking every 10 minutes to
catch this — work with X to design a robust solution") is a create: the
mechanism is the deliverable. A frustrated message that asks someone to go and
check on people is not.

ORDERING. If the message orders two asks ("once all of that is done…", "then",
"after that"), set `blockedBy` on the later record to the INDEX of the record
it waits for.

`assignee` is a 64-hex pubkey or null. A name in prose is not a pubkey — use
null unless you were given the hex."#;

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

    fn raw(json: &str) -> Vec<RawItem> {
        parse_items(json).expect("fixture should parse")
    }

    fn check(json: &str) -> Extraction {
        validate(raw(json), &input_with_board(), &known())
    }

    #[test]
    fn parses_a_bare_object() {
        let items = raw(r#"{"items":[{"ask":"a","disposition":"create","subject":"s"}]}"#);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].disposition, "create");
        assert_eq!(items[0].ask, "a");
    }

    #[test]
    fn parses_an_empty_list() {
        assert!(raw(r#"{"items":[]}"#).is_empty());
    }

    #[test]
    fn parses_json_wrapped_in_prose_and_a_fence() {
        // An endpoint that ignores `response_format` is the common case on a
        // local engine, and it must not read as a transport failure.
        let items = raw(
            "Sure! Here you go:\n```json\n{\"items\":[{\"ask\":\"a\",\"disposition\":\"attach\",\"attachTo\":\"x\"}]}\n```\nHope that helps.",
        );
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].disposition, "attach");
    }

    #[test]
    fn a_reply_with_no_json_is_an_error_not_an_empty_extraction() {
        // Silence and "I could not do that" must be distinguishable: an empty
        // list is a decision, a parse failure is not.
        let err = parse_items("I'm not sure what you mean.").unwrap_err();
        assert!(err.contains("no JSON object"), "{err}");
    }

    #[test]
    fn a_truncated_reply_says_it_was_truncated() {
        // This is the fault that cost the first two corpus replays. A reply cut
        // off at the token budget is a half-written object, and calling it
        // "malformed" sends the reader after a model bug instead of a budget.
        let err = parse_items(r#"{"items":[{"ask":"a","disposition":"create","subject":"half a su"#)
            .unwrap_err();
        assert!(err.contains("truncated"), "{err}");
        assert!(err.contains("half a su"), "the tail is the evidence: {err}");
    }

    #[test]
    fn work_nested_under_an_unknown_key_is_a_loud_failure_not_a_quiet_undercount() {
        // The mechanism nobody could rule out for the one-task collapse,
        // because the raw reply was not saved: a model expressing "then once
        // all of that is done" as a nested key inside the first record. The
        // parser used to accept that and publish one task. Now it is an error,
        // which is a retry.
        let err = parse_items(
            r#"{"items":[{"ask":"a","disposition":"create","subject":"s",
                "steps":[{"subject":"b"},{"subject":"c"}]}]}"#,
        )
        .unwrap_err();
        assert!(err.contains("steps"), "the unknown key must be named: {err}");
    }

    #[test]
    fn an_unknown_top_level_key_is_also_a_failure() {
        let err = parse_items(r#"{"items":[],"tasks":[{"subject":"hidden"}]}"#).unwrap_err();
        assert!(err.contains("tasks"), "{err}");
    }

    #[test]
    fn an_empty_list_is_the_none_verdict() {
        let e = check(r#"{"items":[]}"#);
        assert_eq!(e.verdict(), Verdict::None { count: 0 });
        assert!(e.dropped.is_empty());
        assert!(e.error.is_none());
    }

    #[test]
    fn a_per_ask_none_is_a_verdict_not_a_drop() {
        // The thing the two-pass design destroyed: told to emit one task per
        // ask, the classifier lost `none` entirely and turned attaches into
        // creates. Per-ask disposition keeps the three-way judgement alive on
        // every ask.
        let e = check(
            r#"{"items":[
                {"ask":"fix the thing","disposition":"create","subject":"Fix the thing","doneWhen":"it works"},
                {"ask":"are you sure?","disposition":"none","reason":"a challenge, not work"}]}"#,
        );
        assert_eq!(e.verdict(), Verdict::Create { count: 1 });
        assert!(e.dropped.is_empty());
        assert_eq!(e.asks.len(), 2, "the `none` ask is still enumerated");
    }

    #[test]
    fn counts_distinct_subjects_not_array_entries() {
        // A model under prompt pressure repeats itself: two rows of the
        // anti-merge sweep were the same subject twice, and a verdict counting
        // entries read that as decomposition.
        let e = check(
            r#"{"items":[
                {"ask":"a","disposition":"create","subject":"Build the ladder","doneWhen":"x"},
                {"ask":"b","disposition":"create","subject":"build the ladder ","doneWhen":"x"},
                {"ask":"c","disposition":"create","subject":"Fix the art","doneWhen":"y"}]}"#,
        );
        assert_eq!(e.verdict(), Verdict::Create { count: 2 });
        assert_eq!(e.duplicate_subjects(), 1);
        assert_eq!(e.tasks.len(), 3, "the duplicate is still published, just not counted twice");
    }

    #[test]
    fn a_create_with_no_observable_done_when_is_flagged_but_kept() {
        // `non_empty_or(…, "not stated")` is a fail-open that hid a 3x
        // degradation. A create nobody can close is a defect; losing it
        // entirely would be worse.
        let e = check(
            r#"{"items":[
                {"ask":"a","disposition":"create","subject":"Do the thing"},
                {"ask":"b","disposition":"create","subject":"Do the other","doneWhen":"not stated"},
                {"ask":"c","disposition":"create","subject":"Third","doneWhen":"it is shipped"}]}"#,
        );
        assert_eq!(e.tasks.len(), 3);
        assert_eq!(e.thin, vec![0, 1], "both the absent and the vacuous one");
    }

    #[test]
    fn a_create_beside_an_attach_reduces_to_create() {
        let e = check(&format!(
            r#"{{"items":[
                {{"ask":"a","disposition":"attach","attachTo":"{}"}},
                {{"ask":"b","disposition":"create","subject":"one","doneWhen":"done"}}]}}"#,
            "a".repeat(64)
        ));
        assert_eq!(e.verdict(), Verdict::Create { count: 1 });
    }

    #[test]
    fn an_attach_to_an_id_not_on_the_board_is_dropped() {
        let e = check(r#"{"items":[{"ask":"a","disposition":"attach","attachTo":"0000000000000000"}]}"#);
        assert!(e.tasks.is_empty());
        assert_eq!(e.dropped.len(), 1);
        assert!(e.dropped[0].reason.contains("not on the supplied board"), "{:?}", e.dropped);
        assert_eq!(e.verdict(), Verdict::None { count: 0 });
    }

    #[test]
    fn two_attaches_to_the_same_board_item_collapse_to_one() {
        // wren's residual risk on a mixed message: the same board item named
        // twice is one link, and publishing it twice is two notifications for
        // one fact.
        let e = check(&format!(
            r#"{{"items":[
                {{"ask":"a","disposition":"attach","attachTo":"{id}","note":"first"}},
                {{"ask":"b","disposition":"attach","attachTo":"{id}","note":"second"}}]}}"#,
            id = "a".repeat(64)
        ));
        assert_eq!(e.verdict(), Verdict::Attach { count: 1 });
        assert!(e.dropped.is_empty(), "a collapse is not a validation failure");
    }

    #[test]
    fn a_create_with_an_empty_subject_is_dropped() {
        let e = check(r#"{"items":[{"ask":"a","disposition":"create","subject":"   "}]}"#);
        assert!(e.tasks.is_empty());
        assert!(e.dropped[0].reason.contains("empty subject"));
    }

    #[test]
    fn a_subject_over_the_tag_limit_is_dropped_not_truncated() {
        let long = "x".repeat(MAX_SUBJECT_CHARS + 1);
        let e = check(&format!(
            r#"{{"items":[{{"ask":"a","disposition":"create","subject":"{long}"}}]}}"#
        ));
        assert!(e.tasks.is_empty());
        assert!(e.dropped[0].reason.contains("over the"), "{:?}", e.dropped);
    }

    #[test]
    fn blocked_by_indexes_records_and_is_remapped_onto_the_published_tasks() {
        // `blockedBy` counts the model's records; a dropped record shifts every
        // later task index. Without the remap the link silently points at the
        // wrong task, which is worse than no link.
        let e = check(
            r#"{"items":[
                {"ask":"a","disposition":"create","subject":"first","doneWhen":"x"},
                {"ask":"b","disposition":"attach","attachTo":"nope"},
                {"ask":"c","disposition":"create","subject":"third","doneWhen":"x","blockedBy":0}]}"#,
        );
        assert_eq!(e.tasks.len(), 2);
        assert_eq!(e.dropped.len(), 1);
        assert!(matches!(&e.tasks[1], TaskAction::Create { blocked_by: Some(0), .. }));
    }

    #[test]
    fn a_blocked_by_that_cannot_be_used_loses_the_link_not_the_task() {
        // The ordering is worth less than the work.
        for bad in [r#""blockedBy":7"#, r#""blockedBy":0"#] {
            let e = check(&format!(
                r#"{{"items":[{{"ask":"a","disposition":"create","subject":"only","doneWhen":"x",{bad}}}]}}"#
            ));
            assert_eq!(e.tasks.len(), 1, "{bad}");
            assert!(matches!(&e.tasks[0], TaskAction::Create { blocked_by: None, .. }), "{bad}");
            assert!(e.dropped.is_empty(), "{bad}");
        }
    }

    #[test]
    fn an_unknown_assignee_creates_unassigned_rather_than_dropping_the_task() {
        // `buzz issues assign` with a pubkey nobody holds is a signed no-op
        // that reads as unassigned forever. Losing the assignment is
        // survivable; losing the task is the failure this project exists to
        // remove.
        let e = check(&format!(
            r#"{{"items":[{{"ask":"a","disposition":"create","subject":"s","doneWhen":"x","assignee":"{}"}}]}}"#,
            "f".repeat(64)
        ));
        assert_eq!(e.tasks.len(), 1);
        assert!(matches!(&e.tasks[0], TaskAction::Create { assignee: None, .. }));
        assert!(e.dropped.is_empty());
    }

    #[test]
    fn a_known_assignee_survives() {
        let e = check(&format!(
            r#"{{"items":[{{"ask":"a","disposition":"create","subject":"s","doneWhen":"x","assignee":"{}"}}]}}"#,
            "c".repeat(64)
        ));
        assert!(matches!(&e.tasks[0], TaskAction::Create { assignee: Some(_), .. }));
    }

    #[test]
    fn the_ask_rides_with_the_task_so_provenance_is_on_the_board() {
        let e = check(
            r#"{"items":[{"ask":"get rid of rock 2","disposition":"create","subject":"Retire rock2","doneWhen":"x"}]}"#,
        );
        assert_eq!(e.tasks[0].ask(), "get rid of rock 2");
    }

    #[test]
    fn a_malformed_record_does_not_cost_its_siblings() {
        let e = check(
            r#"{"items":[
                {"ask":"a","disposition":"create","subject":"good","doneWhen":"x"},
                {"ask":"b","disposition":"attach","attachTo":"nope"},
                {"ask":"c","disposition":"create","subject":"also good","doneWhen":"x"}]}"#,
        );
        assert_eq!(e.tasks.len(), 2);
        assert_eq!(e.dropped.len(), 1);
        assert_eq!(e.verdict(), Verdict::Create { count: 2 });
    }

    #[test]
    fn an_unknown_disposition_is_dropped_and_named() {
        let e = check(r#"{"items":[{"ask":"a","disposition":"delete","subject":"s"}]}"#);
        assert!(e.tasks.is_empty());
        assert!(e.dropped[0].reason.contains("unknown disposition"));
    }

    #[test]
    fn a_runaway_array_is_capped() {
        let items: Vec<String> = (0..MAX_ITEMS + 20)
            .map(|i| format!(r#"{{"ask":"a{i}","disposition":"create","subject":"s{i}","doneWhen":"x"}}"#))
            .collect();
        let e = check(&format!(r#"{{"items":[{}]}}"#, items.join(",")));
        assert_eq!(e.tasks.len(), MAX_ITEMS);
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
    fn the_schema_binds_the_count_the_prose_used_to_ask_for() {
        // The whole redesign in one assertion set. There is no second array
        // whose `]` is a fresh decision, every record must name its own ask and
        // disposition, and nothing may be nested where the parser cannot see
        // it.
        let schema = output_schema(&board());
        assert_eq!(schema["additionalProperties"], serde_json::json!(false));
        assert_eq!(
            schema["required"],
            serde_json::json!(["items"]),
            "one array, not two"
        );
        let shapes = schema["properties"]["items"]["items"]["oneOf"].as_array().unwrap();
        assert_eq!(shapes.len(), 3, "one shape per disposition");
        let mut seen = Vec::new();
        for shape in shapes {
            assert_eq!(shape["additionalProperties"], serde_json::json!(false));
            let d = shape["properties"]["disposition"]["enum"][0].as_str().unwrap();
            seen.push(d.to_string());
            let required: Vec<&str> =
                shape["required"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
            assert!(required.contains(&"ask") && required.contains(&"disposition"));
            // Per-disposition requirements are the point. A flat schema that
            // asked only for `ask` and `disposition` let the model emit
            // `{"disposition":"attach","subject":"","note":"…"}` with no
            // attachTo at all, on all three attach rows of the first run.
            match d {
                "create" => {
                    assert!(required.contains(&"subject"), "create must name a subject");
                    assert!(required.contains(&"doneWhen"), "a task nobody can close is a defect");
                }
                "attach" => assert!(required.contains(&"attachTo"), "attach must name its target"),
                "none" => assert!(!required.contains(&"subject")),
                other => panic!("unexpected disposition {other}"),
            }
        }
        seen.sort();
        assert_eq!(seen, vec!["attach", "create", "none"]);
    }

    #[test]
    fn free_text_fields_are_bounded_so_a_repetition_loop_cannot_eat_the_budget() {
        // Measured: at temperature 0 with an unbounded `why`, the model wrote
        // "properly cleanly fast well nicely reliably" for hundreds of tokens
        // on the corpus's first utterance, and every `doneWhen` after it went
        // unwritten because the budget was gone — four creates, none of them
        // closable.
        let schema = output_schema(&board());
        for shape in schema["properties"]["items"]["items"]["oneOf"].as_array().unwrap() {
            for (name, prop) in shape["properties"].as_object().unwrap() {
                if matches!(name.as_str(), "why" | "doneWhen" | "note" | "reason" | "ask" | "subject")
                {
                    assert!(
                        prop["maxLength"].is_number(),
                        "{name} is unbounded free text"
                    );
                }
            }
        }
    }

    #[test]
    fn attach_to_is_an_enum_of_the_ids_actually_on_the_board() {
        // A hallucinated id becomes unreachable rather than rejected after the
        // fact, and attaching becomes a choice the decoder can already see —
        // where creating still costs a fresh subject and doneWhen. Three prose
        // attempts at the same effect recovered at most a quarter of `attach`.
        let schema = output_schema(&board());
        let shapes = schema["properties"]["items"]["items"]["oneOf"].as_array().unwrap();
        let attach = shapes
            .iter()
            .find(|s| s["properties"]["disposition"]["enum"][0] == "attach")
            .expect("an attach shape when the board is non-empty");
        let ids: Vec<&str> = attach["properties"]["attachTo"]["enum"]
            .as_array()
            .expect("attachTo must be an enum, not a free string")
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(ids, vec!["a".repeat(64), "b".repeat(64)]);
    }

    #[test]
    fn an_empty_board_offers_no_attach_shape_at_all() {
        // An enum with no members is not a legal schema, and an attach the
        // harness would have to drop is worse than one the model could never
        // propose.
        let schema = output_schema(&[]);
        let shapes = schema["properties"]["items"]["items"]["oneOf"].as_array().unwrap();
        assert_eq!(shapes.len(), 2);
        assert!(
            !shapes.iter().any(|s| s["properties"]["disposition"]["enum"][0] == "attach"),
            "nothing to attach to"
        );
    }

    #[test]
    fn the_board_enum_is_capped_with_the_board_itself() {
        let big: Vec<BoardTask> = (0..MAX_BOARD_ENTRIES + 10)
            .map(|i| BoardTask {
                id: format!("{i:064}"),
                subject: format!("task {i}"),
                state: "open".into(),
                assignee: None,
            })
            .collect();
        let schema = output_schema(&big);
        let shapes = schema["properties"]["items"]["items"]["oneOf"].as_array().unwrap();
        let attach = shapes
            .iter()
            .find(|s| s["properties"]["disposition"]["enum"][0] == "attach")
            .unwrap();
        // The prompt only lists MAX_BOARD_ENTRIES rows; offering the decoder an
        // id the model was never shown is an attach nobody can justify.
        assert_eq!(attach["properties"]["attachTo"]["enum"].as_array().unwrap().len(), MAX_BOARD_ENTRIES);
    }

    #[test]
    fn the_prompt_states_the_asymmetry_the_gate_scores() {
        // Measured, not assumed. The first version buried the asymmetry under a
        // long list of `none` examples and scored 5/11 with four false `none`s;
        // the same model answered correctly once the asymmetry led.
        assert!(SYSTEM_PROMPT.contains("WHEN IN DOUBT"));
        assert!(SYSTEM_PROMPT.contains("EXTRACT"));
        assert!(SYSTEM_PROMPT.contains("never noticed again"));
    }

    #[test]
    fn the_prompt_no_longer_argues_with_the_schema() {
        // The count rule and the closing self-check are gone: prose asking the
        // model to re-check its own output is what made `doneWhen` absent go
        // from 30% of creates to 85%. Under `response_format` there is no going
        // back, so the check ran in thinking and starved the output.
        assert!(!SYSTEM_PROMPT.contains("THESE ARE THE SAME NUMBER"));
        assert!(!SYSTEM_PROMPT.contains("LAST STEP"));
        assert!(!SYSTEM_PROMPT.contains("Count `asks`"));
        // What is left is judgement, which is the part prose is for.
        assert!(SYSTEM_PROMPT.contains("NOT tone"));
        assert!(SYSTEM_PROMPT.contains("copied from OPEN TASKS"));
        // Measured: the per-ask schema took the gate from 3 of 8 to 8 of 8 and
        // cost `attach` — three rows went from 8/8 and 7/8 to 0/8, 1/8 and
        // 2/8. "Prefer create to none" is right; "prefer create to attach" is
        // how a board fills with duplicates, and the prompt has to say so.
        assert!(SYSTEM_PROMPT.contains("does NOT make `create` the safe answer"));
        assert!(SYSTEM_PROMPT.contains("look down the OPEN TASKS list FIRST"));

        assert!(SYSTEM_PROMPT.contains("blockedBy"));
    }

    /// A stub endpoint replying with each of `replies` in turn, recording every
    /// request body it was sent.
    async fn stub_endpoint(
        replies: Vec<String>,
    ) -> (String, std::sync::Arc<std::sync::Mutex<Vec<serde_json::Value>>>) {
        let bodies: std::sync::Arc<std::sync::Mutex<Vec<serde_json::Value>>> =
            std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let recorded = bodies.clone();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let mut n = 0usize;
            loop {
                let Ok((mut sock, _)) = listener.accept().await else { return };
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                while let Ok(read) = sock.read(&mut chunk).await {
                    if read == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..read]);
                    if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        if let Ok(v) = serde_json::from_slice(&buf[pos + 4..]) {
                            recorded.lock().unwrap().push(v);
                            break;
                        }
                    }
                }
                let reply = replies.get(n).or_else(|| replies.last()).cloned().unwrap_or_default();
                n += 1;
                let body = reply.into_bytes();
                let head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = sock.write_all(head.as_bytes()).await;
                let _ = sock.write_all(&body).await;
                let _ = sock.shutdown().await;
            }
        });
        (format!("http://{addr}"), bodies)
    }

    fn reply_with(content: &str) -> String {
        serde_json::json!({
            "choices": [{ "finish_reason": "stop", "message": { "content": content } }]
        })
        .to_string()
    }

    fn cfg_for(endpoint: String, attempts: u32) -> TaskExtractConfig {
        TaskExtractConfig {
            endpoint,
            model: "m".into(),
            timeout_ms: 5_000,
            max_tokens: 100,
            reasoning_effort: None,
            attempts,
            temperature: 0.0,
        }
    }

    #[tokio::test]
    async fn a_failing_endpoint_is_asked_exactly_attempts_times_then_reported() {
        // The retry has to be bounded and the give-up has to be an `error`, not
        // an empty verdict. Both halves are load-bearing: unbounded retries
        // stall the turn, and a silent give-up is the bug this module was
        // written to remove.
        let truncated = serde_json::json!({
            "choices": [{ "finish_reason": "length", "message": {} }]
        })
        .to_string();
        let (endpoint, bodies) = stub_endpoint(vec![truncated]).await;
        let extraction = TaskExtractor::new(None, HashSet::new())
            .extract(&cfg_for(endpoint, 3), &input_with_board())
            .await;

        assert_eq!(extraction.verdict(), Verdict::None { count: 0 });
        let err = extraction.error.expect("a give-up must be an error, not a verdict");
        assert!(err.contains("truncated"), "{err}");

        let sent = bodies.lock().unwrap();
        assert_eq!(sent.len(), 3, "bounded at `attempts`");
        let temps: Vec<f64> = sent
            .iter()
            .filter_map(|b| b.pointer("/temperature").and_then(|v| v.as_f64()))
            .collect();
        assert_eq!(temps[0], 0.0, "the first ask is greedy");
        assert!(
            temps[1..].iter().all(|t| *t > 0.0),
            "a retry must take a different path through the model: {temps:?}"
        );
        let budgets: Vec<u64> = sent
            .iter()
            .filter_map(|b| b.pointer("/max_tokens").and_then(|v| v.as_u64()))
            .collect();
        assert_eq!(budgets, vec![100, 200, 400], "the budget doubles on a retry");
    }

    #[tokio::test]
    async fn a_parse_failure_keeps_the_bytes_that_failed() {
        // The one row where the raw text names the bug instantly. A schema
        // field the Rust struct spells differently (`noOpenTaskCovers` against
        // `noneOpenTaskCovers` — one character) failed every call on the
        // corpus, and the detail file said `rawReply: null` because the reply
        // was lost to `?` before it could be attached.
        let content = r#"{"items":[{"ask":"a","disposition":"create","surprise":"x"}]}"#;
        let (endpoint, _) = stub_endpoint(vec![reply_with(content)]).await;
        let extraction = TaskExtractor::new(None, HashSet::new())
            .extract(&cfg_for(endpoint, 2), &input_with_board())
            .await;
        let err = extraction.error.expect("an unknown field is a failure");
        assert!(err.contains("surprise"), "{err}");
        assert_eq!(
            extraction.raw_reply.as_deref(),
            Some(content),
            "the bytes that failed are the evidence"
        );
    }

    #[tokio::test]
    async fn the_raw_reply_and_finish_reason_are_kept_for_the_replay() {
        // Nobody could rule out a nesting explanation for the one-task collapse
        // because the raw text was not saved. It is now.
        let content = r#"{"items":[{"ask":"a","disposition":"create","subject":"s","doneWhen":"x"}]}"#;
        let (endpoint, _) = stub_endpoint(vec![reply_with(content)]).await;
        let extraction = TaskExtractor::new(None, HashSet::new())
            .extract(&cfg_for(endpoint, 3), &input_with_board())
            .await;
        assert_eq!(extraction.raw_reply.as_deref(), Some(content));
        assert_eq!(extraction.finish_reason.as_deref(), Some("stop"));
        assert_eq!(extraction.verdict(), Verdict::Create { count: 1 });
    }

    #[tokio::test]
    async fn the_configured_temperature_is_what_the_first_ask_uses() {
        // A sweep at 0.0 is one draw plus endpoint noise. Comparing two prompts
        // needs this knob, so it has to reach the wire.
        let (endpoint, bodies) = stub_endpoint(vec![reply_with(r#"{"items":[]}"#)]).await;
        let mut cfg = cfg_for(endpoint, 1);
        cfg.temperature = 0.7;
        let _ = TaskExtractor::new(None, HashSet::new()).extract(&cfg, &input_with_board()).await;
        assert_eq!(
            bodies.lock().unwrap()[0].pointer("/temperature").and_then(|v| v.as_f64()),
            Some(0.7)
        );
    }

    #[test]
    fn config_defaults_are_the_measured_ones() {
        let defaulted: TaskExtractConfig =
            serde_json::from_str(r#"{"endpoint":"http://x/v1","model":"m"}"#).unwrap();
        assert_eq!(defaulted.max_tokens, 8_000);
        assert_eq!(defaulted.attempts, 3);
        assert_eq!(defaulted.timeout_ms, 20_000);
        assert_eq!(defaulted.temperature, 0.0, "production wants the mode");
        // `low` cuts thinking 5x and costs the decomposition with it.
        assert!(defaulted.reasoning_effort.is_none());
    }
}
