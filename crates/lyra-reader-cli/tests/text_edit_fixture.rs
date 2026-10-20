//! `lyra-reader-cli text-edit analyze`: read-only run discovery on the committed fixture.
//!
//! The fixture is one page with two editable shapes (`Tj` and a `TJ` array without numeric
//! adjustments) and one of every structural refusal: a `TJ` string between kerning numbers, a
//! clipped run, a rotated run and text inside a form XObject. The test asserts the JSON contract
//! the feature report uses, including the conservative/default policy boundary.

mod common;

use serde_json::Value;
use std::process::Command;

fn analyze(extra: &[&str]) -> Option<Value> {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: no PDFium");
        return None;
    }
    let fixture = common::fixture("text-edit.pdf");
    let mut command = Command::new(env!("CARGO_BIN_EXE_lyra-reader-cli"));
    command
        .args(["text-edit", "analyze"])
        .arg(fixture)
        .arg("--json");
    command.args(extra);
    let output = command.output().expect("run CLI");
    assert!(
        output.status.success(),
        "CLI failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    Some(serde_json::from_slice(&output.stdout).expect("valid JSON"))
}

#[test]
fn conservative_policy_reports_only_structural_safe_runs() {
    let Some(json) = analyze(&[]) else { return };
    assert_eq!(json["policy"], "conservative");
    assert_eq!(json["totals"]["editableRuns"], 3);
    assert_eq!(json["totals"]["textCharacters"], 49);
    assert_eq!(json["pages"][0]["tjBoundaries"], 1);

    let texts: Vec<&str> = json["pages"][0]["runs"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|run| run["refusal"].is_null())
        .map(|run| run["text"].as_str().unwrap())
        .collect();
    assert_eq!(texts, ["Hello world", "Plain", " array"]);

    let refusals = json["totals"]["refusals"].as_object().unwrap();
    assert_eq!(refusals["tjKerningAdjustment"]["runs"], 2);
    assert_eq!(refusals["formXObject"]["runs"], 1);
    assert_eq!(refusals["clippedText"]["runs"], 1);
    assert_eq!(refusals["rotatedText"]["runs"], 1);
}

#[test]
fn analysis_only_tj_flag_widens_the_report_but_not_the_structural_rules() {
    let Some(json) = analyze(&["--include-tj-adjustments"]) else {
        return;
    };
    assert_eq!(json["policy"], "allowTjKerning");
    assert_eq!(json["totals"]["editableRuns"], 5);
    let refusals = json["totals"]["refusals"].as_object().unwrap();
    assert!(!refusals.contains_key("tjKerningAdjustment"));
    assert_eq!(refusals["formXObject"]["runs"], 1);
    assert_eq!(refusals["clippedText"]["runs"], 1);
    assert_eq!(refusals["rotatedText"]["runs"], 1);
}
