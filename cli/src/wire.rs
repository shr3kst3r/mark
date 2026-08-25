//! The CLI half of ADR-3's wire protocol: newline-delimited JSON,
//! request/response, versioned.
//!
//! The app's half is `app/Sources/Mark/IPC/CommandRouter.swift`. There are two
//! implementations because there are two languages, not because there are two
//! designs; the shape is small enough — a version, a name, a string map — that
//! the round trip is asserted end to end in `cli/tests/ipc.rs` and again in
//! `scripts/integration.sh` rather than trusted.
//!
//! Plan §1 sketched these types as `core/src/wire.rs`, "shared with the CLI".
//! They live here instead: the *only* Rust consumer is this binary — the app
//! decodes in Swift — so putting them in the core would grow the core's surface
//! for no sharing, and `core` is where ADR-1 keeps a deliberately small,
//! string-shaped C ABI.
//!
//! Arguments are a `String -> String` map on purpose. A `mark://` URL's query
//! items already are one, so the socket meets the URL on the URL's terms and
//! the app has exactly one argument parser to keep both entry paths honest —
//! which is the drift ADR-3 warns about.

use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Serialize};

/// ADR-3: *"Every socket command carries a protocol version, and the app must
/// respond intelligibly to a version it does not know."* This is the one the
/// app answers to; `MARK_PROTOCOL_VERSION` overrides it so the mismatch path
/// can be exercised without building a second CLI.
pub fn protocol_version() -> u32 {
    std::env::var("MARK_PROTOCOL_VERSION")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(1)
}

/// One request line.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Request {
    pub version: u32,
    /// Echoed by the app, so a pipelined client can match replies. One request
    /// per connection today; the field costs 12 bytes and removes a whole class
    /// of future bug.
    pub id: String,
    pub command: String,
    pub arguments: BTreeMap<String, String>,
}

impl Request {
    pub fn new(command: &str) -> Request {
        Request {
            version: protocol_version(),
            id: format!("{}", std::process::id()),
            command: command.to_owned(),
            arguments: BTreeMap::new(),
        }
    }

    #[must_use]
    pub fn arg(mut self, key: &str, value: impl Into<String>) -> Request {
        self.arguments.insert(key.to_owned(), value.into());
        self
    }

    /// Only when `value` is true: a `false` flag and an absent flag mean the
    /// same thing, and sending `"tab":"false"` would make a hand-read log line
    /// look like the user asked for something.
    #[must_use]
    pub fn flag(self, key: &str, value: bool) -> Request {
        if value { self.arg(key, "1") } else { self }
    }

    /// The line to write, without its newline — framing belongs to the caller.
    pub fn encode(&self) -> String {
        // Every field is a string or a number, so this cannot fail; a panic
        // here would be a bug in serde, not in a user's input.
        serde_json::to_string(self).expect("a request is always serializable")
    }
}

/// One response line.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Response {
    #[serde(default)]
    pub version: u32,
    #[serde(default)]
    pub id: Option<String>,
    pub ok: bool,
    #[serde(default)]
    pub result: serde_json::Value,
    #[serde(default)]
    pub error: Option<RemoteError>,
}

/// The app's refusal, as ADR-3 requires: *"the CLI can surface real errors —
/// 'anchor not found' exits non-zero rather than silently succeeding."*
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct RemoteError {
    pub code: String,
    pub message: String,
    /// Everything else the app attached — expected/received versions, the tab
    /// index that was out of range. Kept so `--json` can pass it through
    /// without this type needing to know every code.
    #[serde(flatten)]
    pub detail: BTreeMap<String, serde_json::Value>,
}

impl fmt::Display for RemoteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for RemoteError {}

impl RemoteError {
    /// The exit code an agent scripts against.
    ///
    /// Plan §3 fixes 2 for a missing file and 3 for a task index out of range,
    /// and stops there; the IPC codes below extend it in the direction those
    /// two establish. The distinction that matters to a caller is *whose*
    /// fault it is — the app could not be reached (4) versus the app was
    /// reached and said no (5) — because only the first is worth retrying.
    pub fn exit_code(&self) -> u8 {
        match self.code.as_str() {
            "not-found" => crate::EXIT_FILE,
            _ => crate::EXIT_REFUSED,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_carries_its_protocol_version() {
        let request = Request::new("open").arg("path", "/tmp/x.md");
        let json: serde_json::Value = serde_json::from_str(&request.encode()).unwrap();
        assert_eq!(json["version"], serde_json::json!(protocol_version()));
        assert_eq!(json["command"], serde_json::json!("open"));
        assert_eq!(json["arguments"]["path"], serde_json::json!("/tmp/x.md"));
    }

    #[test]
    fn a_false_flag_is_absent_rather_than_false() {
        let with = Request::new("open").arg("path", "/x").flag("tab", true);
        let without = Request::new("open").arg("path", "/x").flag("tab", false);
        assert_eq!(with.arguments.get("tab").map(String::as_str), Some("1"));
        assert!(!without.arguments.contains_key("tab"));
    }

    #[test]
    fn a_failure_response_decodes_with_its_detail() {
        let line = r#"{"version":1,"ok":false,"error":{"code":"unsupported-version",
            "message":"this mark speaks 1","expected":1,"received":99}}"#;
        let response: Response = serde_json::from_str(line).unwrap();
        assert!(!response.ok);
        let error = response.error.expect("an error");
        assert_eq!(error.code, "unsupported-version");
        assert_eq!(error.detail["received"], serde_json::json!(99));
        assert_eq!(error.exit_code(), crate::EXIT_REFUSED);
    }

    #[test]
    fn a_missing_file_keeps_the_exit_code_the_local_commands_use() {
        let error = RemoteError {
            code: "not-found".to_owned(),
            message: "/nope.md: no such file".to_owned(),
            detail: BTreeMap::new(),
        };
        assert_eq!(error.exit_code(), crate::EXIT_FILE);
    }

    #[test]
    fn a_success_response_without_a_result_still_decodes() {
        let response: Response = serde_json::from_str(r#"{"version":1,"ok":true}"#).unwrap();
        assert!(response.ok);
        assert!(response.result.is_null());
        assert!(response.error.is_none());
    }
}
