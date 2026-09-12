//! The last module the binary touches, so an edit here is a link-dominated rebuild.

use crate::pipeline::Summary;

pub fn render(summary: &Summary) -> String {
    serde_json::to_string_pretty(summary).unwrap_or_else(|error| format!("{{\"error\":\"{error}\"}}"))
}
