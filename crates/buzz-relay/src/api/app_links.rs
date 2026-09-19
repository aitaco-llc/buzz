//! Apple universal links for invite URLs.

use std::sync::Arc;

use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Json, Response},
};
use serde_json::{json, Value};

use crate::state::AppState;

/// Paths an associated app opens in place of Safari. Only the invite landing
/// page (`/invite/<code>`, minted by `api::invites`) hands off to an app.
const APP_LINK_PATH: &str = "/invite/*";

/// `GET /.well-known/apple-app-site-association`.
///
/// Served only when `BUZZ_APPLE_APP_IDS` names at least one app, and always
/// directly: Apple refuses an association file behind a redirect. `Json` sets
/// `Content-Type: application/json`, which Apple also requires.
pub async fn apple_app_site_association(State(state): State<Arc<AppState>>) -> Response {
    let app_ids = &state.config.apple_app_ids;
    if app_ids.is_empty() {
        return StatusCode::NOT_FOUND.into_response();
    }
    Json(association_document(app_ids)).into_response()
}

/// Each app gets both key sets: `appIDs` and `components`, which iOS 13 and
/// later read, and the older `appID` and `paths`.
fn association_document(app_ids: &[String]) -> Value {
    let details: Vec<Value> = app_ids
        .iter()
        .map(|app_id| {
            json!({
                "appIDs": [app_id],
                "components": [{ "/": APP_LINK_PATH }],
                "appID": app_id,
                "paths": [APP_LINK_PATH],
            })
        })
        .collect();
    json!({ "applinks": { "apps": [], "details": details } })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn document_names_every_app_for_invite_paths_only() {
        let doc = association_document(&["5F7YLJS4YR.co.aitaco.buzz".to_string()]);
        assert_eq!(
            doc,
            json!({
                "applinks": {
                    "apps": [],
                    "details": [{
                        "appIDs": ["5F7YLJS4YR.co.aitaco.buzz"],
                        "components": [{ "/": "/invite/*" }],
                        "appID": "5F7YLJS4YR.co.aitaco.buzz",
                        "paths": ["/invite/*"],
                    }],
                },
            })
        );
    }
}
