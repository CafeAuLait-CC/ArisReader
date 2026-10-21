//! Run cache-dependent tests in child processes with private, writable cache directories.
//! Command::env changes only the child environment; parallel tests never mutate process-global
//! environment variables or touch the user's real application cache.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

struct CacheDirectory(PathBuf);
impl Drop for CacheDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Returns true only inside the isolated child that should execute the test body.
pub fn isolated(test: &str) -> bool {
    const CHILD: &str = "LYRA_READER_INDEX_CACHE_TEST_CHILD";
    if std::env::var(CHILD).as_deref() == Ok(test) {
        return true;
    }
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let directory = CacheDirectory(std::env::temp_dir().join(format!(
        "lyra-isolated-index-{}-{}-{stamp}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    )));
    fs::create_dir(&directory.0).expect("reserve isolated cache directory");
    let output = Command::new(std::env::current_exe().expect("test executable"))
        .args(["--exact", test, "--nocapture"])
        .env(CHILD, test)
        .env("LYRA_READER_INDEX_CACHE_DIR", directory.0.join("Indexes"))
        .env_remove("LYRA_READER_INDEX_CACHE")
        .output()
        .expect("run isolated cache test");
    assert!(
        output.status.success()
            && String::from_utf8_lossy(&output.stdout).contains("1 passed; 0 failed"),
        "isolated test {test} failed ({}):\n{}\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    false
}
