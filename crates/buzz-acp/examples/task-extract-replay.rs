//! Replay the labelled corpus through the real extractor and write a
//! predictions file `scripts/task-extractor/task-extractor-eval.py` can score.
//!
//! ```text
//! scripts/task-extractor/task-extractor-eval.py --fetch > utterances.json
//!
//! # Track 1 — "will production pass?": greedy, board built as it goes.
//! cargo run -p buzz-acp --example task-extract-replay -- \
//!     --utterances utterances.json --out predictions.json --detail detail.json
//!
//! # Track 2 — "is prompt B better than A?": sampled, and the board held still.
//! cargo run -p buzz-acp --example task-extract-replay -- \
//!     --utterances utterances.json --write-board-snapshot board.json --out /dev/null
//! cargo run -p buzz-acp --example task-extract-replay -- \
//!     --utterances utterances.json --board-snapshot board.json \
//!     --temperature 0.7 --out predictions.json
//! ```
//!
//! # Two tracks, because they answer different questions
//!
//! **Greedy is one sample.** Eight replays at `temperature: 0` against a
//! byte-identical prompt are one draw plus endpoint noise, not eight
//! observations — they tell you the mode and nothing about the spread around
//! it. That is the right instrument for "will the fleet pass the gate", and the
//! wrong one for "is this prompt better". A prompt comparison needs
//! `--temperature 0.7` and k ≥ 8.
//!
//! **And the board is an input.** The corpus ships labels, not a board, and
//! `attach` is undecidable without one: "where are we with assessing spark
//! 1.3?" attaches, "where are we at in all our initiatives?" does not, and
//! nothing in the text separates them. So the default replay walks the window
//! in order and grows the board as it goes — the board at utterance N is what
//! 1..N-1 created, which is what the live path does.
//!
//! That fidelity has a cost for comparison: a miss **cascades**, so the board a
//! later utterance sees varies run to run, and some of what looks like model
//! variance is input variance. `--board-snapshot` pins it. Produce one with
//! `--write-board-snapshot` from a sequential run, then hold it fixed across
//! both arms.
//!
//! The synthetic issue ids are derived from the source event id so a prediction
//! can be traced back to the utterance that created its attach target.

use std::collections::HashMap;
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
    board_snapshot: Option<PathBuf>,
    write_board_snapshot: Option<PathBuf>,
    endpoint: String,
    model: String,
    reasoning_effort: Option<String>,
    temperature: f64,
}

fn parse_args() -> Args {
    let mut utterances = None;
    let mut out = None;
    let mut detail = None;
    let mut board_snapshot = None;
    let mut write_board_snapshot = None;
    let mut endpoint = "https://generativelanguage.googleapis.com/v1beta/openai".to_string();
    let mut model = "gemini-3.8-flash".to_string();
    let mut reasoning_effort: Option<String> = None;
    let mut temperature = 0.0;
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--utterances" => utterances = it.next().map(PathBuf::from),
            "--out" => out = it.next().map(PathBuf::from),
            "--detail" => detail = it.next().map(PathBuf::from),
            "--board-snapshot" => board_snapshot = it.next().map(PathBuf::from),
            "--write-board-snapshot" => write_board_snapshot = it.next().map(PathBuf::from),
            "--endpoint" => endpoint = it.next().unwrap_or(endpoint),
            "--model" => model = it.next().unwrap_or(model),
            "--temperature" => {
                temperature = it.next().and_then(|v| v.parse().ok()).unwrap_or(temperature)
            }
            // `none` sends no field at all, so the endpoint's own default
            // thinking budget applies.
            "--reasoning-effort" => reasoning_effort = it.next().filter(|v| v != "none"),
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
        board_snapshot,
        write_board_snapshot,
        endpoint,
        model,
        reasoning_effort,
        temperature,
    }
}

/// A board id for the `n`th task created by `event_id`.
///
/// Traceable on sight: the first 62 hex of the source event, then the index.
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

    let utterances: Vec<Utterance> = serde_json::from_slice(&std::fs::read(&args.utterances)?)?;
    let pinned: Option<HashMap<String, Vec<BoardTask>>> = match &args.board_snapshot {
        Some(p) => Some(serde_json::from_slice(&std::fs::read(p)?)?),
        None => None,
    };
    eprintln!(
        "replaying {} utterances through {} at {}",
        utterances.len(),
        args.model,
        args.endpoint
    );
    eprintln!(
        "  temperature={}  reasoning_effort={}  board={}",
        args.temperature,
        args.reasoning_effort.as_deref().unwrap_or("<endpoint default>"),
        if pinned.is_some() { "pinned snapshot" } else { "grown sequentially" }
    );

    let cfg = TaskExtractConfig {
        endpoint: args.endpoint,
        model: args.model,
        timeout_ms: 60_000,
        max_tokens: 8_000,
        reasoning_effort: args.reasoning_effort.clone(),
        attempts: 3,
        temperature: args.temperature,
    };
    // No roster: the corpus has no pubkeys, and an empty known-set means the
    // extractor accepts any well-formed 64-hex assignee rather than rejecting
    // every one. Scoring is on action and count, not assignment.
    let extractor = TaskExtractor::new(api_key, HashSet::new());

    let mut board: Vec<BoardTask> = Vec::new();
    let mut snapshot: HashMap<String, Vec<BoardTask>> = HashMap::new();
    let mut predictions = serde_json::Map::new();
    let mut detail = Vec::new();
    let mut errors = 0usize;
    let mut thin_total = 0usize;
    let mut dup_total = 0usize;

    for u in &utterances {
        let board_for_row = match &pinned {
            Some(p) => p.get(&u.id).cloned().unwrap_or_default(),
            None => board.clone(),
        };
        snapshot.insert(u.id.clone(), board_for_row.clone());

        let input = ExtractInput {
            message: Some(SourceMessage {
                id: u.event_id.clone(),
                channel: u.channel.clone(),
                author: String::new(),
                text: u.text.clone(),
                thread_root: None,
            }),
            thread_context: vec![],
            board: board_for_row,
        };
        let board_before = input.board.len();
        let extraction = extractor.extract(&cfg, &input).await;
        if let Some(err) = &extraction.error {
            // A failed call and a `none` verdict both publish nothing. Scoring
            // them the same is how the first run of this corpus reported four
            // model verdicts that were really a prompt the model never
            // answered — and how a later comparison table called a regression
            // catastrophic when it was merely worse.
            eprintln!("  !! {} EXTRACTION FAILED: {err}", u.id);
            errors += 1;
        }
        let duplicates = extraction.duplicate_subjects();
        thin_total += extraction.thin.len();
        dup_total += duplicates;

        let (action, count) = match extraction.verdict() {
            Verdict::Create { count } => ("create", count),
            Verdict::Attach { count } => ("attach", count),
            Verdict::None { count } => ("none", count),
        };
        println!(
            "  {:<10} {:<7} count={}  asks={}  board={}  dup={}  thin={}  dropped={}",
            u.id,
            action,
            count,
            extraction.asks.len(),
            board_before,
            duplicates,
            extraction.thin.len(),
            extraction.dropped.len()
        );
        // `thin` and `duplicates` ride with the prediction so the scorer can
        // count a create nobody can close as the defect it is, rather than as
        // work extracted.
        predictions.insert(
            u.id.clone(),
            serde_json::json!({
                "action": action,
                "count": count,
                "thin": extraction.thin.len(),
                "duplicates": duplicates,
                "asks": extraction.asks.len(),
                "error": extraction.error.is_some(),
            }),
        );

        let mut emitted = Vec::new();
        for task in extraction.tasks.iter() {
            match task {
                TaskAction::Create { ask, subject, done_when, blocked_by, .. } => {
                    let id = synthetic_id(&u.event_id, board.len());
                    emitted.push(serde_json::json!({
                        "ask": ask, "id": id, "subject": subject,
                        "doneWhen": done_when, "blockedBy": blocked_by
                    }));
                    if pinned.is_none() {
                        board.push(BoardTask {
                            id,
                            subject: subject.clone(),
                            state: "open".into(),
                            assignee: None,
                        });
                    }
                }
                TaskAction::Attach { ask, attach_to, note } => {
                    emitted.push(serde_json::json!({
                        "ask": ask, "attachTo": attach_to, "note": note
                    }));
                }
            }
        }
        detail.push(serde_json::json!({
            "id": u.id,
            "action": action,
            "count": count,
            "boardBefore": board_before,
            "asks": extraction.asks,
            "tasks": emitted,
            "thin": extraction.thin,
            "duplicates": duplicates,
            "dropped": extraction
                .dropped
                .iter()
                .map(|d| serde_json::json!({ "index": d.index, "reason": d.reason }))
                .collect::<Vec<_>>(),
            "error": extraction.error,
            // The evidence that was missing when the one-task collapse had to
            // be explained: key order shows what the model wrote first, and an
            // unknown key shows work nested where the parser cannot see it.
            "finishReason": extraction.finish_reason,
            "rawReply": extraction.raw_reply,
        }));
    }

    std::fs::write(&args.out, serde_json::to_string_pretty(&predictions)? + "\n")?;
    eprintln!("wrote {}", args.out.display());
    if let Some(path) = &args.detail {
        std::fs::write(path, serde_json::to_string_pretty(&detail)? + "\n")?;
        eprintln!("wrote {}", path.display());
    }
    if let Some(path) = &args.write_board_snapshot {
        std::fs::write(path, serde_json::to_string_pretty(&snapshot)? + "\n")?;
        eprintln!("wrote {} (pin it with --board-snapshot)", path.display());
    }
    eprintln!("defects: {thin_total} creates with no observable doneWhen, {dup_total} duplicate subjects");
    if errors > 0 {
        eprintln!(
            "\n{errors} of {} extractions never got an answer. The predictions file is \
             written, but it is NOT a model result: an errored row scores as `none` and \
             will read as a deliberate verdict. Exclude those rows from any denominator, \
             and say how many there were.",
            utterances.len()
        );
        std::process::exit(1);
    }
    Ok(())
}
