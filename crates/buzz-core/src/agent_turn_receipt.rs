//! NIP-AR: the public per-turn receipt — what a turn ran on, and what it spent.
//!
//! [`KIND_AGENT_TURN_RECEIPT`] is the plaintext, channel-scoped sibling of
//! [`KIND_AGENT_TURN_METRIC`](crate::kind::KIND_AGENT_TURN_METRIC). The metric
//! is the owner's ledger: encrypted to them, carrying no `h` tag so a relay
//! operator cannot see which channel a turn served. The receipt is the room's:
//! it binds a turn's model and token counts to the messages that turn published,
//! so the people who asked for the work can see what answering them cost.
//!
//! # Shape
//!
//! ```text
//! kind    44201
//! tags    ["h", <channel uuid>]            exactly one
//!         ["e", <message event id>]        one per published message, in order
//!         ["model", <model id>]            exactly one, for filtering
//! content {"model":…,"harness":…,"turn":{…}}
//! ```
//!
//! # Trust
//!
//! A receipt is an unsigned-for claim in the only sense that matters: anyone may
//! publish one `e`-tagging anyone's message. A consumer MUST ignore a receipt
//! whose `pubkey` differs from the author of the message it would annotate, and
//! SHOULD render a turn's usage once rather than under every message the turn
//! produced — the counts are the turn's, not any one message's.

use serde::{Deserialize, Serialize};

use crate::agent_turn_metric::TokenCounts;

/// The receipt's `content`, as JSON.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentTurnReceiptPayload {
    /// The model the turn actually ran on, as the harness observed it — not as
    /// it was configured. A seat whose configured model never applied reports
    /// what it really used here, which is the point.
    pub model: String,

    /// Harness identifier (`"claude-agent-acp"`, `"rebrand-acp"`, `"goose"`).
    pub harness: String,

    /// This turn's usage. Absent fields mean the harness reported none — a
    /// zero would be a claim the provider never made.
    pub turn: TokenCounts,
}

/// How a receipt fails to be one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReceiptError {
    /// `model` or `harness` was empty.
    Empty(&'static str),
    /// A cost was negative or not finite.
    Cost,
}

impl std::fmt::Display for ReceiptError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ReceiptError::Empty(field) => write!(f, "{field} must not be empty"),
            ReceiptError::Cost => write!(f, "cost_usd must be finite and non-negative"),
        }
    }
}

impl std::error::Error for ReceiptError {}

impl AgentTurnReceiptPayload {
    /// Check the invariants a reader would otherwise have to assume.
    pub fn validate(&self) -> Result<(), ReceiptError> {
        if self.model.trim().is_empty() {
            return Err(ReceiptError::Empty("model"));
        }
        if self.harness.trim().is_empty() {
            return Err(ReceiptError::Empty("harness"));
        }
        match self.turn.cost_usd {
            Some(cost) if !cost.is_finite() || cost < 0.0 => Err(ReceiptError::Cost),
            _ => Ok(()),
        }
    }

    /// Whether this receipt says anything a reader could act on. A turn whose
    /// harness reported no counts at all still names its model, which is the
    /// half of the answer that never comes from the provider.
    pub fn reports_usage(&self) -> bool {
        self.turn.input_tokens.is_some()
            || self.turn.output_tokens.is_some()
            || self.turn.total_tokens.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload() -> AgentTurnReceiptPayload {
        AgentTurnReceiptPayload {
            model: "opus[1m]".into(),
            harness: "claude-agent-acp".into(),
            turn: TokenCounts {
                input_tokens: Some(191_261),
                output_tokens: Some(683),
                total_tokens: Some(191_944),
                cost_usd: None,
                cache_read_tokens: Some(122_407),
                cache_write_tokens: None,
            },
        }
    }

    #[test]
    fn a_receipt_names_its_model_and_harness() {
        assert!(payload().validate().is_ok());
        for (field, bad) in [
            (
                "model",
                AgentTurnReceiptPayload {
                    model: "  ".into(),
                    ..payload()
                },
            ),
            (
                "harness",
                AgentTurnReceiptPayload {
                    harness: String::new(),
                    ..payload()
                },
            ),
        ] {
            assert_eq!(bad.validate(), Err(ReceiptError::Empty(field)));
        }
    }

    #[test]
    fn a_cost_that_is_not_a_cost_is_refused() {
        for bad in [-0.01, f64::NAN, f64::INFINITY] {
            let mut p = payload();
            p.turn.cost_usd = Some(bad);
            assert_eq!(p.validate(), Err(ReceiptError::Cost), "{bad}");
        }
    }

    #[test]
    fn a_turn_the_harness_could_not_count_still_names_its_model() {
        let mut p = payload();
        p.turn = TokenCounts {
            input_tokens: None,
            output_tokens: None,
            total_tokens: None,
            cost_usd: None,
            cache_read_tokens: None,
            cache_write_tokens: None,
        };
        assert!(p.validate().is_ok());
        assert!(!p.reports_usage());
        assert!(payload().reports_usage());
    }

    #[test]
    fn absent_counts_stay_absent_through_a_round_trip() {
        // A zero is a claim the provider never made; `null` is the truth.
        let mut p = payload();
        p.turn.cost_usd = None;
        let json = serde_json::to_string(&p).expect("serialize");
        assert!(json.contains("\"costUsd\":null"), "{json}");
        assert!(
            !json.contains("cacheWrite"),
            "absent optionals are omitted: {json}"
        );
        assert_eq!(
            serde_json::from_str::<AgentTurnReceiptPayload>(&json).expect("round trip"),
            p
        );
    }
}
