//! Network-call guard for the AI layer.
//!
//! The audit trail is local only. This test makes that claim enforceable: it fails when the AI
//! layer gains a network call that is not on the documented list below, when one of the listed
//! calls disappears or is duplicated, or when an analytics/telemetry identifier appears without
//! an explicit opt-in allowlist entry.
//!
//! Documented request paths (the complete list today):
//!
//! 1. **API-key transport**: `crates/lyra-reader-ai/src/openai.rs`, one `ureq` agent and one
//!    `agent.post(&spec.url)`. The URL is the endpoint of the previewed `ChatPlan`, so the host
//!    is the reader's configured provider — never a second hard-coded destination.
//! 2. **ChatGPT plan transport**: `ChatGPTResponses.swift`, one `URLRequest` to the fixed
//!    `https://api.openai.com/v1/responses` endpoint.
//! 3. **ChatGPT sign-in**: `ChatGPTSignIn.swift`, OAuth token/authorize/revocation and
//!    discovery calls under `auth.openai.com`, the model catalog under `api.openai.com`, and a
//!    loopback (`127.0.0.1`) listener for the browser callback. These carry credentials and a
//!    model list, never document content.
//!
//! The scan is line-based and skips full-line comments. It deliberately fails on any new marker
//! anywhere in the scanned trees instead of trying to infer intent: adding a legitimate path is
//! a small, visible edit to this list, which is the point of the guard.

use std::fs;
use std::path::{Path, PathBuf};

/// One allowed network call site. `count` is the number of occurrences of `marker` in the
/// file's non-comment code with all whitespace removed, so a call split across lines is still
/// counted. A missing or duplicated call fails the guard, so the list cannot drift.
struct AllowedSite {
    path: &'static str,
    marker: &'static str,
    count: usize,
}

const ALLOWED_SITES: &[AllowedSite] = &[
    AllowedSite {
        path: "crates/lyra-reader-ai/src/openai.rs",
        marker: "ureq::Agent::with_parts(",
        count: 1,
    },
    AllowedSite {
        path: "crates/lyra-reader-ai/src/openai.rs",
        marker: "DefaultConnector::new()",
        count: 1,
    },
    AllowedSite {
        path: "crates/lyra-reader-ai/src/openai.rs",
        marker: "agent.post(",
        count: 1,
    },
    AllowedSite {
        path: "apps/macos/Sources/LyraReaderKit/ChatGPTResponses.swift",
        marker: "URLRequest(",
        count: 1,
    },
    AllowedSite {
        path: "apps/macos/Sources/LyraReaderKit/ChatGPTResponses.swift",
        marker: "session.bytes(for:",
        count: 1,
    },
    AllowedSite {
        path: "apps/macos/Sources/LyraReaderKit/ChatGPTSignIn.swift",
        marker: "URLRequest(",
        count: 3,
    },
    AllowedSite {
        path: "apps/macos/Sources/LyraReaderKit/ChatGPTSignIn.swift",
        marker: "session.data(",
        count: 5,
    },
    AllowedSite {
        path: "apps/macos/Sources/LyraReaderKit/ChatGPTSignIn.swift",
        marker: "URLSession",
        count: 5,
    },
    AllowedSite {
        path: "apps/macos/Sources/LyraReaderKit/ChatGPTSignIn.swift",
        marker: "NWListener(",
        count: 1,
    },
    AllowedSite {
        path: "apps/macos/Sources/LyraReaderKit/ChatGPTSignIn.swift",
        marker: "NWConnection",
        count: 2,
    },
];

/// Markers that mean "this line makes, configures, or receives a network call". Any occurrence
/// outside `ALLOWED_SITES` fails, regardless of the file's name, so a new telemetry module
/// cannot slip in beside the AI code.
const NETWORK_MARKERS: &[&str] = &[
    "URLSession",
    "URLRequest(",
    "NWListener(",
    "NWConnection",
    "session.data(",
    "session.bytes(for:",
    "agent.post(",
    "ureq::Agent::with_parts(",
    "DefaultConnector::new()",
    "TcpStream",
    "TcpListener",
    "UdpSocket",
    "reqwest::",
    "hyper::",
    "isahc::",
    "curl::",
    "CFStream",
    "NSURLConnection",
    "WebSocket",
];

/// Analytics/telemetry identifiers. None may appear without an `OPT_IN_SITES` entry and the
/// explicit opt-in gate below. The list is intentionally about upload/reporting, not the words
/// "local" or "privacy".
const TELEMETRY_MARKERS: &[&str] = &[
    "analytics",
    "telemetry",
    "posthog",
    "sentry",
    "mixpanel",
    "amplitude",
    "crashlytics",
    "firebase",
    "bugsnag",
    "datadog",
    "appcenter",
];

/// Files allowed to mention an analytics/telemetry identifier. Empty today. A future opt-in
/// upload path must add its file here *and* read the explicit gate token in that same file.
const OPT_IN_SITES: &[(&str, &str)] = &[];

/// The token a file must contain before it may be listed in `OPT_IN_SITES`: an explicit,
/// user-facing consent decision, not a default-on setting.
const OPT_IN_GATE: &str = "explicitUserOptIn";

/// Literals that pin the two request paths to their fixed destinations. The API-key path is
/// deliberately absent: its destination is the reader's configured endpoint, which is why that
/// path may only exist inside the one previewed `RequestSpec` transport.
const REQUIRED_LITERALS: &[(&str, &str)] = &[
    (
        "apps/macos/Sources/LyraReaderKit/ChatGPTResponses.swift",
        "https://api.openai.com/v1/responses",
    ),
    (
        "apps/macos/Sources/LyraReaderKit/ChatGPTSignIn.swift",
        "https://auth.openai.com/.well-known/openid-configuration",
    ),
    (
        "apps/macos/Sources/LyraReaderKit/ChatGPTSignIn.swift",
        "https://auth.openai.com/api/accounts/oauth/token",
    ),
    (
        "apps/macos/Sources/LyraReaderKit/ChatGPTSignIn.swift",
        "https://auth.openai.com/api/accounts/authorize",
    ),
];

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("the crate lives at <repo>/crates/lyra-reader-ai")
        .to_path_buf()
}

fn collect_files(root: &Path, extension: &str, output: &mut Vec<PathBuf>) -> std::io::Result<()> {
    if !root.exists() {
        return Ok(());
    }
    for entry in fs::read_dir(root)? {
        let path = entry?.path();
        if path.is_dir() {
            // Generated by scripts/build-rust.sh; not part of the reviewed AI layer.
            if path.file_name().and_then(|name| name.to_str()) == Some("LyraReaderBindings") {
                continue;
            }
            collect_files(&path, extension, output)?;
        } else if path.extension().and_then(|value| value.to_str()) == Some(extension) {
            output.push(path);
        }
    }
    Ok(())
}

fn is_comment(line: &str) -> bool {
    let trimmed = line.trim_start();
    trimmed.starts_with("//")
        || trimmed.starts_with("/*")
        || trimmed.starts_with('*')
        || trimmed.starts_with("*/")
}

fn relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

#[test]
fn only_the_documented_ai_network_paths_exist() {
    let root = repo_root();
    let swift_root = root.join("apps/macos/Sources");
    assert!(
        swift_root.is_dir(),
        "network guard: {} is missing; the guard cannot check the AI layer",
        swift_root.display()
    );

    let mut files = Vec::new();
    for directory in [
        root.join("crates/lyra-reader-ai/src"),
        root.join("crates/lyra-reader-ffi/src"),
    ] {
        collect_files(&directory, "rs", &mut files).expect("walk the Rust AI layer");
    }
    collect_files(&swift_root, "swift", &mut files).expect("walk the Swift shell");

    let mut violations: Vec<String> = Vec::new();
    let mut seen_sites = vec![false; ALLOWED_SITES.len()];

    for file in &files {
        let path = relative(&root, file);
        let source = fs::read_to_string(file)
            .unwrap_or_else(|error| panic!("cannot read {}: {error}", file.display()));
        // Strip full-line comments, then collapse every kind of whitespace: a call split over
        // several lines is still a call, and the guard must not be evadable by formatting.
        let code: String = source
            .lines()
            .filter(|line| !is_comment(line))
            .collect::<Vec<_>>()
            .join("\n");
        let squashed: String = code
            .chars()
            .filter(|character| !character.is_whitespace())
            .collect();

        for (slot, site) in ALLOWED_SITES.iter().enumerate() {
            if site.path != path {
                continue;
            }
            let count = squashed.matches(site.marker).count();
            if count != site.count {
                violations.push(format!(
                    "{path}: expected {} occurrence(s) of `{}`, found {count}",
                    site.count, site.marker
                ));
            }
            if count > 0 {
                seen_sites[slot] = true;
            }
        }

        for marker in NETWORK_MARKERS {
            let documented = ALLOWED_SITES
                .iter()
                .any(|site| site.path == path && site.marker == *marker);
            if documented {
                continue;
            }
            let count = squashed.matches(marker).count();
            if count > 0 {
                violations.push(format!(
                    "{path} calls the network with `{marker}` {count} time(s), which is not on the documented list"
                ));
            }
        }

        // Telemetry identifiers are scanned line by line: squashing whitespace could invent a
        // word across a line break (`sent` + `ry`). The network markers above still use the
        // squashed form so a call split across lines cannot evade the guard.
        for (index, raw) in source.lines().enumerate() {
            if is_comment(raw) {
                continue;
            }
            let line = raw.to_ascii_lowercase();
            for marker in TELEMETRY_MARKERS {
                if !line.contains(marker) {
                    continue;
                }
                let opted_in = OPT_IN_SITES
                    .iter()
                    .any(|(site, token)| *site == path && line.contains(token));
                let has_gate = source.contains(OPT_IN_GATE);
                if !opted_in || !has_gate {
                    violations.push(format!(
                        "{path}:{} mentions `{marker}` without an explicit opt-in gate (`{OPT_IN_GATE}`)",
                        index + 1
                    ));
                }
            }
        }

        for (required_path, literal) in REQUIRED_LITERALS {
            if *required_path == path && !source.contains(literal) {
                violations.push(format!(
                    "{path}: the documented request literal `{literal}` is missing"
                ));
            }
        }
    }

    for (slot, site) in ALLOWED_SITES.iter().enumerate() {
        if !seen_sites[slot] {
            violations.push(format!(
                "{}: the documented network site `{}` is missing (update the guard only if the transport really moved)",
                site.path, site.marker
            ));
        }
    }

    assert!(
        violations.is_empty(),
        "the AI network-call guard found {} problem(s):\n  - {}",
        violations.len(),
        violations.join("\n  - ")
    );

    // A short, explicit statement of what was verified. It is part of the test output so a
    // reader of CI logs sees the allowed list without opening this file.
    println!(
        "network guard: {} file(s) scanned; allowed calls: API-key transport (one ureq agent, the previewed endpoint), ChatGPT Responses (fixed api.openai.com/v1/responses), ChatGPT sign-in (auth.openai.com + api.openai.com/models + loopback callback); no analytics/telemetry identifiers",
        files.len()
    );
}
