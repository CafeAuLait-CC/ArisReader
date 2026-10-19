//! Path resolution shared by the CLI integration tests.
//!
//! `CARGO_MANIFEST_DIR` is compiled into each test binary. This repository keeps one `target/`
//! directory for several checkouts, so cargo can run a binary that was built in a checkout which
//! has since been removed; the compiled-in path then points into a tree that no longer exists
//! even though the checkout running the tests has the fixtures and corpora. Resolving paths at
//! run time from the working directory (cargo starts a test binary in its package root) keeps the
//! tests independent of which checkout happened to compile the binary.
//!
//! The local corpora (`pdf-samples/`, `eval-papers/`) are never committed; the environment
//! variables still take precedence and a missing directory is reported by the caller, not here.

#![allow(dead_code)]

use std::path::{Path, PathBuf};

/// The repository root, resolved at run time.
pub fn repo_root() -> PathBuf {
    if let Ok(current_dir) = std::env::current_dir() {
        for ancestor in current_dir.ancestors() {
            if ancestor.join("Cargo.toml").is_file() && ancestor.join("crates").is_dir() {
                return ancestor.to_path_buf();
            }
        }
    }
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..")
}

/// A committed fixture under `tests/fixtures/`.
///
/// # Panics
///
/// Panics with the resolved path when the fixture is missing: a missing committed fixture is a
/// broken test setup, not something a test should skip past.
pub fn fixture(name: &str) -> PathBuf {
    let path = repo_root().join("tests/fixtures").join(name);
    assert!(
        path.is_file(),
        "committed test fixture {name:?} is missing (looked for {}; cwd={:?})",
        path.display(),
        std::env::current_dir(),
    );
    path
}

/// The local PDF sample corpus, honouring `LYRA_READER_PDF_SAMPLES`.
pub fn samples_dir() -> PathBuf {
    std::env::var_os("LYRA_READER_PDF_SAMPLES")
        .map(PathBuf::from)
        .unwrap_or_else(|| repo_root().join("pdf-samples"))
}
