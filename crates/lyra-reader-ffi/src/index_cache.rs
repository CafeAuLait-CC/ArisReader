//! The persistent document index cache.
//!
//! Opening a PDF is cheap; deriving the reader's index from it is not. The reference list, the
//! figure/table captions, the outline, the recognised metadata and the per-page citation spans
//! are all read out of the text and object layers, and that work was repeated on every open. This
//! module stores that derived index beside the PDF and reuses it when the **bytes** the index was
//! built from are the same bytes the reader has just opened.
//!
//! # Identity: the file's content, never its metadata
//!
//! A cache is bound to `sha256(content) + byte length`. Modification times, file sizes, inode
//! numbers and paths are not part of the identity: `touch` changes only the mtime, a copy can
//! keep the same mtime and length, and a rebuild can change the size. SHA-256 over the whole
//! file is collision-resistant, so a wrong cache can only be used if two different files have
//! the same digest — which is the same assumption every content-addressed cache makes. The
//! length is carried too so a malformed header cannot claim a digest for a file of a different
//! length; it is never used on its own.
//!
//! Validation therefore costs one sequential read of the PDF (hashed while reading) plus parsing
//! one small JSON file. On the measured 115-page sample that is one order of magnitude below
//! re-deriving the index; [`crate::api::LyraReaderDocument::index_cache_report`] reports both times.
//!
//! # File and compatibility
//!
//! The sidecar is `<document>.pdf.lyra-reader-index.json`, next to the PDF, following the annotation
//! sidecar's naming precedent (`<document>.pdf.lyra-reader-annotations.json`). It is a JSON object with
//! a `kind` tag and a `format_version`. The contract is:
//!
//! * **Older or same format, same bytes** — read. Unknown top-level keys make the file
//!   *incompatible*: it is ignored and preserved untouched, because another LyraReader may own it.
//! * **Newer format** — ignored and preserved untouched, before any field is interpreted. The
//!   version is checked first, so a future schema cannot be half-read.
//! * **Corrupt, truncated, wrong kind** — ignored; the document is parsed from scratch and a new
//!   cache replaces the damaged one after a complete index exists.
//! * **Unreadable or oversized** — ignored and preserved, since the reader cannot prove what it
//!   is looking at.
//!
//! A cache is disposable; derived values are never edited by the user, so unlike the annotation
//! sidecar there is nothing to merge. The compatibility rule is still conservative: a file this
//! build cannot fully understand is left alone rather than rewritten from a partial reading.
//!
//! # Atomicity
//!
//! Writes go to a uniquely named temporary file in the same directory, are flushed and
//! `sync_all`ed, and only then renamed over the final path. A crash before the rename leaves the
//! old cache (or none); a crash during the rename leaves one of the two complete files. A partial
//! JSON document can therefore never be observed at the cache path. Write failures — a read-only
//! directory, a full disk — are silent: the reader keeps the freshly derived index in memory and
//! the next open simply pays the parse again.

use crate::api::{
    CitationRecord, DocumentMetadataRecord, FigureRecord, OutlineEntry, ReferenceRecord,
};
use lyra_reader_text::CitationStyle;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// The schema version this build writes and understands.
///
/// Bump this whenever a persisted field changes meaning, is removed, or a fresh parse would
/// return different values for the same bytes (for example a caption detector change). The
/// version is the cache's whole compatibility contract; `ENGINE_VERSION` is informational.
///
/// # 2 (T4.12 / T4.13)
///
/// Version 1 caches were written by the caption detector that read a wrapped prose line as a
/// caption, and by the index that stopped at page 120. Both defects are fixed by *deleting*
/// entries from the persisted `figures` list and by *adding* pages to `citations`; a version-1
/// sidecar for unchanged PDF bytes would therefore be a hit and the fix would stay invisible —
/// the old false positives would keep entering the index and page 121+ would stay empty. The
/// version is bumped so every version-1 cache is re-derived from the document. The layout is
/// otherwise unchanged; the bump is about the values, which is exactly what this constant
/// documents.
///
/// # 3 (T4.42)
///
/// The reference half gained the document's other reference lists (`lists` and
/// `document_wide`): a page-aware citation resolution needs them to attribute a citation to its
/// section's list. A version-2 sidecar has only the document-wide list, so using it would make
/// an appendix citation resolve into the main list again. Every version-2 cache is therefore
/// re-derived once; the replacement carries the lists.
///
/// # 4
///
/// Outline entries gained the reader's bookmark identity (`bookmark_id`) and its page-local Y
/// (`y_pt`). A version-3 cache cannot supply either, so it is re-derived instead of being
/// returned without the data that makes a saved bookmark clickable at its position.
pub(crate) const FORMAT_VERSION: u32 = 4;

/// Tag that identifies our sidecar (a JSON file at the right name is not enough).
pub(crate) const KIND: &str = "lyra-reader-document-index";

/// Suffix appended to the PDF's own path, matching the annotation sidecar's convention.
pub(crate) const CACHE_SUFFIX: &str = ".lyra-reader-index.json";

/// Largest cache this reader will read. A derived index for a 2000-page manual is far below
/// this; anything larger is not a file this build produced, and is preserved rather than
/// guessed at.
const MAX_CACHE_BYTES: u64 = 64 * 1024 * 1024;

/// Read buffer for hashing. Large enough that the syscall count does not dominate, small enough
/// to stay out of the way of the page cache.
const HASH_BUFFER_BYTES: usize = 256 * 1024;

/// The content identity a cache is bound to.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ContentIdentity {
    /// Lowercase hex SHA-256 over every byte of the PDF.
    pub sha256: String,
    /// Length of the hashed file, in bytes.
    pub bytes: u64,
}

impl ContentIdentity {
    /// Hashes `path` in one sequential pass. The file is read again by the PDF backend on its own
    /// schedule; hashing does not share the backend's handle, so this cannot disturb a page read.
    pub(crate) fn of(path: &Path) -> io::Result<Self> {
        let file = File::open(path)?;
        let mut reader = BufReader::with_capacity(HASH_BUFFER_BYTES, file);
        let mut hasher = Sha256::new();
        let mut buffer = vec![0u8; HASH_BUFFER_BYTES];
        let mut bytes = 0u64;
        loop {
            let read = reader.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
            bytes += read as u64;
        }
        let digest = hasher.finalize();
        let sha256 = digest
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        Ok(Self { sha256, bytes })
    }
}

/// One reference list in the persisted index: its entries, and the evidence a citation
/// attribution needs (the same fields `lyra_reader_text::ReferenceList` carries live).
///
/// The records carry view-space geometry so a resolved entry can be previewed straight from a
/// cache hit; the text library's live entries are not persisted because their page-space glyph
/// ranges are derivable from a fresh parse and are not needed to resolve or attribute a label.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CachedReferenceList {
    pub records: Vec<ReferenceRecord>,
    pub numbered: bool,
    pub heading: Option<String>,
    pub heading_page: Option<u32>,
    pub section: Option<lyra_reader_text::SectionRef>,
    pub region_start: Option<u32>,
}

/// The reference half of the index: the entries and the citation style they imply, plus every
/// list so a citation can be attributed to the one its page belongs to.
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CachedReferences {
    pub style: CitationStyle,
    /// The document-wide list's records. Kept alongside `lists` because it is what
    /// `LyraReaderDocument::references` has always returned and what a caller with no page resolves
    /// against.
    pub records: Vec<ReferenceRecord>,
    /// Every list, in reading order.
    pub lists: Vec<CachedReferenceList>,
    /// Index of the document-wide list in `lists`.
    pub document_wide: u32,
}

/// The complete persisted index.
///
/// Every field is required. A cache missing one of them is not "partly usable": it is not this
/// format, and is re-derived from the PDF instead of being handed back with a hole in it.
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct IndexCacheFile {
    pub kind: String,
    pub format_version: u32,
    /// Written for diagnostics only; `format_version` is what compatibility is decided by.
    pub engine_version: String,
    pub content: ContentIdentity,
    pub page_count: u32,
    pub outline: Vec<OutlineEntry>,
    pub references: CachedReferences,
    pub figures: Vec<FigureRecord>,
    pub metadata: DocumentMetadataRecord,
    /// Per-page citation spans, in view space. Pages not in the map are derived on demand.
    pub citations: BTreeMap<u32, Vec<CitationRecord>>,
}

/// What reading the sidecar found.
pub(crate) enum CacheRead {
    Hit(Box<IndexCacheFile>),
    Stale,
    Missing,
    Corrupt { detail: String },
    Incompatible { detail: String },
    FutureVersion { version: u64 },
    Unreadable { detail: String },
}

/// Top-level keys this build understands. Anything else means another writer owns the file; it
/// is preserved and the reader falls back to a full parse.
const KNOWN_KEYS: [&str; 10] = [
    "kind",
    "format_version",
    "engine_version",
    "content",
    "page_count",
    "outline",
    "references",
    "figures",
    "metadata",
    "citations",
];

/// `<pdf>.lyra-reader-index.json`, built as an `OsString` so a non-UTF-8 document path keeps working.
pub(crate) fn cache_path(document_path: &Path) -> PathBuf {
    let mut path = document_path.as_os_str().to_os_string();
    path.push(CACHE_SUFFIX);
    PathBuf::from(path)
}

/// Whether this environment asks for the cache to be off. The native regression suite sets it so
/// checks never write sidecars into the committed fixtures; the app does not set it.
pub(crate) fn disabled_by_environment() -> bool {
    match std::env::var("LYRA_READER_INDEX_CACHE") {
        Ok(value) => matches!(
            value.to_ascii_lowercase().as_str(),
            "0" | "off" | "false" | "disabled" | "none"
        ),
        Err(_) => false,
    }
}

/// Reads and validates the cache at `path` against `identity` and `page_count`.
///
/// The order matters: the magic and version are checked before any typed field is parsed, so a
/// future cache is never partially interpreted.
pub(crate) fn read_cache(path: &Path, identity: &ContentIdentity, page_count: u32) -> CacheRead {
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return CacheRead::Missing,
        Err(error) => {
            return CacheRead::Unreadable {
                detail: error.to_string(),
            };
        }
    };
    if !metadata.is_file() {
        return CacheRead::Corrupt {
            detail: "the cache path is not a regular file".to_string(),
        };
    }
    if metadata.len() > MAX_CACHE_BYTES {
        return CacheRead::Unreadable {
            detail: format!("{MAX_CACHE_BYTES} byte cache limit exceeded"),
        };
    }
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) => {
            return CacheRead::Unreadable {
                detail: error.to_string(),
            };
        }
    };
    let value: serde_json::Value = match serde_json::from_slice(&bytes) {
        Ok(value) => value,
        Err(error) => {
            return CacheRead::Corrupt {
                detail: error.to_string(),
            };
        }
    };
    let Some(object) = value.as_object() else {
        return CacheRead::Corrupt {
            detail: "the cache is not a JSON object".to_string(),
        };
    };
    let version = object
        .get("format_version")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);
    if version > u64::from(FORMAT_VERSION) {
        return CacheRead::FutureVersion { version };
    }
    if object.get("kind").and_then(serde_json::Value::as_str) != Some(KIND) {
        return CacheRead::Corrupt {
            detail: "the cache kind tag is not LyraReader's document index".to_string(),
        };
    }
    if let Some(unknown) = object
        .keys()
        .find(|key| !KNOWN_KEYS.contains(&key.as_str()))
    {
        return CacheRead::Incompatible {
            detail: format!("unknown top-level key {unknown:?}"),
        };
    }
    let file: IndexCacheFile = match serde_json::from_value(value) {
        Ok(file) => file,
        Err(error) => {
            let detail = error.to_string();
            // `deny_unknown_fields` is applied to every persisted struct, so an unknown key
            // inside one is another writer's schema. Treat it like a top-level unknown key:
            // leave the file alone rather than rewriting a partially understood cache.
            if detail.contains("unknown field") {
                return CacheRead::Incompatible { detail };
            }
            return CacheRead::Corrupt { detail };
        }
    };
    if file.format_version != FORMAT_VERSION {
        return CacheRead::Corrupt {
            detail: format!("format version {} is not current", file.format_version),
        };
    }
    if file.content != *identity {
        return CacheRead::Stale;
    }
    if file.page_count != page_count {
        return CacheRead::Stale;
    }
    CacheRead::Hit(Box::new(file))
}

/// Writes `file` atomically at `path`, returning the number of bytes written.
///
/// The temporary name is unique per process and call. `create_new` refuses to reuse a file left
/// by a crashed writer; the rename is the only operation that makes the new cache visible. On any
/// failure the temporary file is removed and the previous cache (if any) is left exactly as it
/// was.
pub(crate) fn write_cache(path: &Path, file: &IndexCacheFile) -> io::Result<u64> {
    let mut bytes = serde_json::to_vec(file).map_err(io::Error::other)?;
    bytes.push(b'\n');

    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "index".to_string());
    static NEXT_TEMPORARY: AtomicU64 = AtomicU64::new(0);
    let sequence = NEXT_TEMPORARY.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(".{name}.tmp-{}-{sequence}", std::process::id()));

    let result = (|| {
        let mut handle = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        handle.write_all(&bytes)?;
        handle.sync_all()?;
        drop(handle);
        fs::rename(&temporary, path)?;
        // Best-effort directory sync so the rename itself survives a crash. Some filesystems
        // reject `sync_all` on a directory; the rename is already atomic without it.
        if let Ok(directory) = File::open(parent) {
            let _ = directory.sync_all();
        }
        Ok(())
    })();

    if let Err(error) = result {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    Ok(bytes.len() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(bytes: &[u8]) -> ContentIdentity {
        let mut hasher = Sha256::new();
        hasher.update(bytes);
        let digest = hasher.finalize();
        ContentIdentity {
            sha256: digest.iter().map(|byte| format!("{byte:02x}")).collect(),
            bytes: bytes.len() as u64,
        }
    }

    fn empty_field() -> crate::api::MetadataFieldRecord {
        crate::api::MetadataFieldRecord {
            values: Vec::new(),
            source: crate::api::MetadataSourceKind::Absent,
            source_code: "absent".to_string(),
            source_label: "no source".to_string(),
            trust: "none".to_string(),
            guessed: false,
        }
    }

    fn empty_metadata() -> DocumentMetadataRecord {
        DocumentMetadataRecord {
            title: empty_field(),
            authors: empty_field(),
            venue: empty_field(),
            year: empty_field(),
            doi: empty_field(),
            arxiv_id: empty_field(),
            bibtex: String::new(),
        }
    }

    fn minimal_file(identity: ContentIdentity) -> IndexCacheFile {
        IndexCacheFile {
            kind: KIND.to_string(),
            format_version: FORMAT_VERSION,
            engine_version: "test".to_string(),
            content: identity,
            page_count: 1,
            outline: Vec::new(),
            references: CachedReferences {
                style: CitationStyle::default(),
                records: Vec::new(),
                lists: Vec::new(),
                document_wide: 0,
            },
            figures: Vec::new(),
            metadata: empty_metadata(),
            citations: BTreeMap::new(),
        }
    }

    #[test]
    fn content_identity_is_the_bytes_not_the_path_or_time() {
        let first = identity(b"%PDF-1.7 first\n");
        let second = identity(b"%PDF-1.7 second\n");
        assert_ne!(first, second);
        assert_eq!(first, identity(b"%PDF-1.7 first\n"));
    }

    #[test]
    fn a_version_one_cache_is_not_read_after_the_caption_and_page_fixes() {
        // T4.12/T4.13 changed what a parse derives for the same bytes (fewer captions, and
        // citations for every page), so a version-1 sidecar would be a plausible-looking hit
        // with the old, wrong values. It is re-derived instead; see `FORMAT_VERSION`.
        let directory =
            std::env::temp_dir().join(format!("lyra-reader-index-cache-v1-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).expect("scratch");
        let path = directory.join("version-one.json");
        let mut value =
            serde_json::to_value(minimal_file(identity(b"same bytes"))).expect("serialize");
        value
            .as_object_mut()
            .expect("cache object")
            .insert("format_version".to_string(), serde_json::Value::from(1u32));
        fs::write(&path, serde_json::to_vec(&value).expect("json")).expect("write cache");
        let cache = read_cache(&path, &identity(b"same bytes"), 1);
        match cache {
            CacheRead::Corrupt { detail } => {
                assert_eq!(detail, "format version 1 is not current", "{detail}");
            }
            _ => panic!("a version-1 cache must not be handed back as a hit"),
        }
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_future_version_is_rejected_before_the_fields_are_parsed() {
        let directory = std::env::temp_dir().join(format!(
            "lyra-reader-index-cache-unit-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).expect("scratch");
        let path = directory.join("future.json");
        fs::write(
            &path,
            br#"{"kind":"lyra-reader-document-index","format_version":9999,"not_a_field":true}"#,
        )
        .expect("write future cache");
        let cache = read_cache(&path, &identity(b"x"), 1);
        assert!(matches!(cache, CacheRead::FutureVersion { version: 9999 }));
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_cache_for_other_bytes_is_stale() {
        let directory = std::env::temp_dir().join(format!(
            "lyra-reader-index-cache-stale-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).expect("scratch");
        let path = directory.join("index.json");
        write_cache(&path, &minimal_file(identity(b"old bytes"))).expect("write cache");
        let cache = read_cache(&path, &identity(b"new bytes"), 1);
        assert!(matches!(cache, CacheRead::Stale));
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn an_unknown_field_is_preserved_rather_than_half_read() {
        let directory = std::env::temp_dir().join(format!(
            "lyra-reader-index-cache-unknown-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).expect("scratch");
        let path = directory.join("index.json");
        let mut value = serde_json::to_value(minimal_file(identity(b"x"))).expect("serialize");
        value
            .as_object_mut()
            .expect("cache object")
            .insert("future_field".to_string(), serde_json::Value::Bool(true));
        fs::write(&path, serde_json::to_vec(&value).expect("json")).expect("write cache");
        let cache = read_cache(&path, &identity(b"x"), 1);
        match cache {
            CacheRead::Incompatible { detail } => {
                assert!(detail.contains("future_field"), "{detail}");
            }
            _ => panic!("an unknown field must not be half-read"),
        }
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_truncated_cache_is_never_a_hit() {
        let directory = std::env::temp_dir().join(format!(
            "lyra-reader-index-cache-truncated-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).expect("scratch");
        let path = directory.join("truncated.json");
        fs::write(&path, br#"{"kind":"lyra-reader-document-index","#).expect("write truncated");
        let cache = read_cache(&path, &identity(b"x"), 1);
        assert!(matches!(cache, CacheRead::Corrupt { .. }));
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn an_atomic_write_replaces_the_previous_file_whole() {
        let directory = std::env::temp_dir().join(format!(
            "lyra-reader-index-cache-write-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).expect("scratch");
        let path = directory.join("index.json");
        let file = minimal_file(identity(b"x"));
        let bytes = write_cache(&path, &file).expect("write cache");
        assert_eq!(
            fs::metadata(&path).expect("cache exists").len(),
            bytes,
            "the reported size is the file the reader will see"
        );
        let again = minimal_file(identity(b"x"));
        write_cache(&path, &again).expect("replace cache");
        let cache = read_cache(&path, &identity(b"x"), 1);
        assert!(matches!(cache, CacheRead::Hit(_)));
        let leftovers: Vec<_> = fs::read_dir(&directory)
            .expect("scratch")
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.file_name().to_string_lossy().contains(".tmp-"))
            .collect();
        assert!(leftovers.is_empty(), "the temporary file was renamed away");
        let _ = fs::remove_dir_all(&directory);
    }
}
