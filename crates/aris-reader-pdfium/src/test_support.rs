//! Helpers shared by this crate's unit tests.
//!
//! They exist to remove two kinds of state that tests must not share:
//!
//! * **The checkout the test binary was compiled in.** `env!("CARGO_MANIFEST_DIR")` is baked
//!   into the binary at compile time. This repository keeps one `target/` directory for several
//!   checkouts (disk budget), so cargo can run a test binary that was compiled in a checkout
//!   that has since been removed; the compiled-in path then points into a tree that no longer
//!   exists while the committed fixtures are present in the checkout currently running the
//!   tests. [`fixture`] therefore resolves a fixture at run time: the working directory and its
//!   ancestors first (cargo starts a test binary in the package root of the checkout it is
//!   running), then the compiled-in path, with an explicit `ARIS_READER_TEST_FIXTURES` override
//!   for unusual layouts.
//!
//! * **Temporary directories keyed only by pid and the clock.** A name built from
//!   `process::id()` plus `SystemTime::now()` is not a reservation: two tests can observe the
//!   same timestamp, and a pre-existing entry with that name can be a symlink or a file.
//!   [`ScratchDir`] reserves a brand-new directory with `create_dir` (which fails atomically if
//!   the name exists), retries with a process-wide sequence number on collision, and removes
//!   the directory when it is dropped — including when a test panics.

use std::env;
use std::fs;
use std::io::ErrorKind;
use std::ops::Deref;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Repository-relative location of the committed fixtures.
const FIXTURE_DIR: &str = "tests/fixtures";

/// Fixed prefix for scratch directories; makes leaked directories recognisable.
const SCRATCH_PREFIX: &str = "aris-test";

/// Returns the committed fixture `name`, searched at run time rather than only at the path the
/// binary happened to be compiled with.
///
/// # Panics
///
/// Panics with every path that was tried when the fixture cannot be found. A missing committed
/// fixture is a broken test setup, not a reason to skip silently.
pub fn fixture(name: &str) -> PathBuf {
    let mut tried = Vec::new();
    for root in fixture_roots() {
        let candidate = root.join(name);
        if candidate.is_file() {
            return candidate;
        }
        tried.push(candidate);
    }
    let tried = tried
        .iter()
        .map(|path| format!("  {}", path.display()))
        .collect::<Vec<_>>()
        .join("\n");
    panic!(
        "test fixture {name:?} was not found. Tried:\n{tried}\n\
         CARGO_MANIFEST_DIR={}\n\
         current_dir={:?}\n\
         Set ARIS_READER_TEST_FIXTURES to the checkout's tests/fixtures directory to override.",
        env!("CARGO_MANIFEST_DIR"),
        env::current_dir(),
    );
}

/// Every directory that could hold the committed fixtures, most specific first.
fn fixture_roots() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Some(override_dir) = env::var_os("ARIS_READER_TEST_FIXTURES")
        && !override_dir.is_empty()
    {
        push_unique(&mut roots, PathBuf::from(override_dir));
    }
    // The checkout currently running the tests wins: cargo starts the test process in its
    // package root, and that is the checkout whose sources are under test even when the binary
    // itself was compiled somewhere else.
    if let Ok(current_dir) = env::current_dir() {
        for ancestor in current_dir.ancestors() {
            push_unique(&mut roots, ancestor.join(FIXTURE_DIR));
        }
    }
    // The normal case when the working directory is not usable: the checkout that compiled this
    // binary is still present.
    push_unique(
        &mut roots,
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join(FIXTURE_DIR),
    );
    roots
}

fn push_unique(paths: &mut Vec<PathBuf>, path: PathBuf) {
    if !paths.iter().any(|existing| existing == &path) {
        paths.push(path);
    }
}

/// Creates a scratch directory for one test. See [`ScratchDir`].
pub fn scratch(label: &str) -> ScratchDir {
    ScratchDir::new(label)
}

/// Makes a copy of a committed fixture inside a test's own scratch directory.
///
/// The source is resolved by [`fixture`]. The destination's parent must already exist; a failure
/// names both paths so a future defect is diagnosed from the panic alone.
pub fn copy_fixture(directory: &Path, source_name: &str, destination_name: &str) -> PathBuf {
    let source = fixture(source_name);
    let destination = directory.join(destination_name);
    fs::copy(&source, &destination).unwrap_or_else(|error| {
        panic!(
            "could not copy test fixture {} to {}: {error}",
            source.display(),
            destination.display()
        )
    });
    destination
}

/// A temporary directory owned by exactly one test.
///
/// The directory is created atomically with a name that is unique within the process (pid +
/// sequence number) and across processes (the directory creation itself is the reservation),
/// so two tests can never share it. Dropping the guard removes the directory, including on the
/// unwind path of a panicking test.
pub struct ScratchDir {
    path: PathBuf,
}

impl ScratchDir {
    /// Creates a fresh, empty directory under the platform temporary directory.
    ///
    /// # Panics
    ///
    /// Panics with the temp root and the underlying error if no directory can be created.
    pub fn new(label: &str) -> Self {
        static NEXT_SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let root = usable_temp_root();
        let label = sanitize_label(label);
        let pid = std::process::id();
        for _ in 0..128 {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let sequence = NEXT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = root.join(format!("{SCRATCH_PREFIX}-{pid}-{sequence}-{nanos}-{label}"));
            match fs::create_dir(&path) {
                Ok(()) => return Self { path },
                Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
                Err(error) => panic!(
                    "could not create test scratch directory {} (temp root {}): {error}",
                    path.display(),
                    root.display()
                ),
            }
        }
        panic!(
            "could not find a free test scratch directory after 128 attempts under {}",
            root.display()
        );
    }
}

impl Deref for ScratchDir {
    type Target = Path;

    fn deref(&self) -> &Path {
        &self.path
    }
}

impl AsRef<Path> for ScratchDir {
    fn as_ref(&self) -> &Path {
        &self.path
    }
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        // Best effort: a test may still hold a file open (PDFium handles are closed before the
        // end of each test, but a panic can unwind in between), and a leftover directory is
        // harmless whereas a panic in Drop would mask the original failure.
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// Creates the platform temporary directory if needed and resolves it to an absolute path.
///
/// A test machine can have an unusual temp directory: `TMPDIR` may point at a directory that
/// was removed, at a relative path, or at a symlink. Canonicalising once makes the scratch path
/// immune to later working-directory changes, and the explicit `create_dir_all` turns an
/// unusable temp root into a diagnostic here rather than a confusing missing-directory error
/// later.
fn usable_temp_root() -> PathBuf {
    let root = env::temp_dir();
    if let Err(error) = fs::create_dir_all(&root) {
        panic!(
            "could not create the platform temporary directory {}: {error}",
            root.display()
        );
    }
    fs::canonicalize(&root).unwrap_or(root)
}

/// Keeps a label usable as one path component on every supported platform.
fn sanitize_label(label: &str) -> String {
    let mut sanitized = String::with_capacity(label.len().min(48));
    for character in label.chars().take(48) {
        if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
            sanitized.push(character);
        } else {
            sanitized.push('_');
        }
    }
    if sanitized.is_empty() {
        "test".to_string()
    } else {
        sanitized
    }
}
