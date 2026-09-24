//! Replay the labelled corpus through the real extractor and write a
//! predictions file `scripts/task-extractor/task-extractor-eval.py` can score.
//!
//! ```text
//! scripts/task-extractor/task-extractor-eval.py --fetch > utterances.json
//! cargo run -p buzz-acp --example task-extract-replay -- \
//!     --utterances utterances.json \
//!     --endpoint https://generativelanguage.googleapis.com/v1beta/openai \
//!     --model gemini-3.8-flash \
//!     --out predictions.json
//! scripts/task-extractor/task-extractor-eval.py --predictions predictions.json
//! ```
//!
//! # Why the replay is sequential, and why it has to be
//!
//! The corpus ships labels, not a board — and **`attach` is undecidable without
//! one**. Two of its utterances are the same sentence shape with different
//! answers:
//!
//! - `17ced753` "where are we with assessing spark 1.3?" → `attach`
//! - `5d472ef8` "where are we at in all our initiatives?" → `none`
//!
//! Nothing in the text separates them. What separates them is that the Spark
//! task is on the board and "all our initiatives" is not one item. An extractor
//! handed an empty board can only answer `create` or `none` to both, so scoring
//! it against those labels would measure the fixture, not the extractor.
//!
//! So the replay walks the window in order and grows the board as it goes: the
//! board at utterance N is what utterances 1..N-1 created. That is also exactly
//! what the live path does, which makes this a rehearsal rather than a
//! simulation. `9aee0484` — the window's first message — is what puts the Spark
//! task on the board for `17ced753` to attach to, nineteen hours later.
//!
//! The synthetic issue ids are derived from the source event id so a prediction
//! can be traced back to the utterance that created its attach target.

use std::collections::HashSet;
use std::path::PathBuf;

use buzz_acp::task_extract::{
    BoardTask, ExtractInput, SourceMessage, TaskAction, TaskExtractConfig, TaskExtractor, Verdict,
};

#[derive(serde::Deserialize)]
struct Utterance {
    id: String,
    #[serde(default)]
    channel: String,
    #[serde(default)]
    text: String,
    #[serde(default, rename = "eventId")]
    event_id: String,
}

struct Args {
    utterances: PathBuf,
    out: PathBuf,
    detail: Option<PathBuf>,
    endpoint: String,
    model: String,
    reasoning_effort: Option<String>,
    two_pass: bool,
}

fn parse_args() -> Args {
    let mut utterances = None;
    let mut out = None;
    let mut detail = None;
    let mut endpoint =
        "https://generativelanguage.googleapis.com/v1beta/openai".to_string();
    let mut model = "gemini-3.8-flash".to_string();
    let mut reasoning_effort: Option<String> = None;
    let mut two_pass = false;
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--utterances" => utterances = it.next().map(PathBuf::from),
            "--out" => out = it.next().map(PathBuf::from),
            "--detail" => detail = it.next().map(PathBuf::from),
            "--endpoint" => endpoint = it.next().unwrap_or(endpoint),
            "--model" => model = it.next().unwrap_or(model),
            // `none` sends no field at all, so the endpoint's own default
            // thinking budget applies.
            "--two-pass" => two_pass = true,
            "--reasoning-effort" => {
                reasoning_effort = it.next().filter(|v| v != "none");
            }
            other => {
                eprintln!("unknown flag {other}");
                std::process::exit(2);
            }
        }
    }
    Args {
        utterances: utterances.unwrap_or_else(|| {
            eprintln!("--utterances is required");
            std::process::exit(2);
        }),
        out: out.unwrap_or_else(|| PathBuf::from("predictions.json")),
        detail,
        endpoint,
        model,
        reasoning_effort,
        two_pass,
    }
}

/// A board id for the `n`th task created by `event_id`.
///
/// Traceable on sight: the first 62 hex of the source event, then the index.
/// Reusing the source keeps a prediction's attach target readable back to the
/// utterance that put it there.
fn synthetic_id(event_id: &str, n: usize) -> String {
    let mut base: String = event_id.chars().filter(|c| c.is_ascii_hexdigit()).take(62).collect();
    while base.len() < 62 {
        base.push('0');
    }
    format!("{base}{:02x}", n & 0xff)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = parse_args();
    let api_key = std::env::var("TASK_EXTRACT_API_KEY").ok().filter(|k| !k.is_empty());
    if api_key.is_none() {
        eprintln!(
            "TASK_EXTRACT_API_KEY is empty. A replay with no key scores the endpoint's \
             401 page, which looks exactly like a model that answered `none` to everything."
        );
        std::process::exit(2);
    }

    let utterances: Vec<Utterance> =
        serde_json::from_slice(&std::fs::read(&args.utterances)?)?;
    eprintln!(
        "replaying {} utterances through {} at {} (reasoning_effort={})",
        utterances.len(),
        args.model,
        args.endpoint,
        args.reasoning_effort.as_deref().unwrap_or("<endpoint default>")
    );
    eprintln!(
        "enumeration: {}",
        if args.two_pass { "its own first pass" } else { "in the classify call" }
    );

    let cfg = TaskExtractConfig {
        endpoint: args.endpoint,
        model: args.model,
        timeout_ms: 60_000,
        max_tokens: 8_000,
        reasoning_effort: args.reasoning_effort.clone(),
        attempts: 3,
        two_pass: args.two_pass,
    };
    // No roster: the corpus has no pubkeys, and an empty known-set means the
    // extractor accepts any well-formed 64-hex assignee rather than rejecting
    // every one. Scoring is on action and count, not assignment.
    let extractor = TaskExtractor::new(api_key, HashSet::new());

    let mut errors = 0usize;
    let mut board: Vec<BoardTask> = Vec::new();
    let mut predictions = serde_json::Map::new();
    let mut detail = Vec::new();

    for u in &utterances {
        let input = ExtractInput {
            message: Some(SourceMessage {
                id: u.event_id.clone(),
                channel: u.channel.clone(),
                author: String::new(),
                text: u.text.clone(),
                thread_root: None,
            }),
            thread_context: vec![],
            board: board.clone(),
        };
        let board_before = board.len();
        let extraction = extractor.extract(&cfg, &input).await;
        if let Some(err) = &extraction.error {
            // A failed call and a `none` verdict both publish nothing. Scoring
            // them the same is how the first run of this corpus reported four
            // model verdicts that were really a prompt the model never
            // answered. Say which, and refuse to exit 0.
            eprintln!("  !! {} EXTRACTION FAILED: {err}", u.id);
            errors += 1;
        }
        let verdict = extraction.verdict();
        let (action, count) = match verdict {
            Verdict::Create { count } => ("create", count),
            Verdict::Attach { count } => ("attach", count),
            Verdict::None { count } => ("none", count),
        };
        println!(
            "  {:<10} {:<7} count={}  board_before={}  dropped={}",
            u.id,
            action,
            count,
            board_before,
            extraction.dropped.len()
        );
        predictions.insert(
            u.id.clone(),
            serde_json::json!({ "action": action, "count": count }),
        );

        let mut created = Vec::new();
        for (n, task) in extraction.tasks.iter().enumerate() {
            match task {
                TaskAction::Create { subject, done_when, .. } => {
                    let id = synthetic_id(&u.event_id, board.len());
                    created.push(serde_json::json!({
                        "id": id, "subject": subject, "doneWhen": done_when
                    }));
                    board.push(BoardTask {
                        id,
                        subject: subject.clone(),
                        state: "open".into(),
                        assignee: None,
                    });
                }
                TaskAction::Attach { attach_to, note } => {
                    created.push(serde_json::json!({
                        "attachTo": attach_to, "note": note, "index": n
                    }));
                }
            }
        }
        detail.push(serde_json::json!({
            "id": u.id,
            "action": action,
            "count": count,
            "boardBefore": board_before,
            "error": extraction.error,
            "asks": extraction.asks,
            "tasks": created,
            "dropped": extraction
                .dropped
                .iter()
                .map(|d| serde_json::json!({ "index": d.index, "reason": d.reason }))
                .collect::<Vec<_>>(),
        }));
    }

    std::fs::write(&args.out, serde_json::to_string_pretty(&predictions)? + "\n")?;
    eprintln!("wrote {}", args.out.display());
    if let Some(path) = args.detail {
        std::fs::write(&path, serde_json::to_string_pretty(&detail)? + "\n")?;
        eprintln!("wrote {}", path.display());
    }
    if errors > 0 {
        eprintln!(
            "\n{errors} of {} extractions never got an answer. The predictions file is \
             written, but it is NOT a model result: an errored row scores as `none` and \
             will read as a deliberate verdict. Fix the transport and replay before \
             quoting any number from it.",
            utterances.len()
        );
        std::process::exit(1);
    }
    Ok(())
}
