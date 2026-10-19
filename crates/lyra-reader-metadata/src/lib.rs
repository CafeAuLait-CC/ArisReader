//! Document metadata recognition and BibTeX export.
//!
//! `recognize` combines the three offline sources available for an open PDF — XMP, the
//! `/Info` dictionary and the first page's text layer — and records the source of every field
//! so the reader can decide whether to trust it. `bibtex` turns those values (after any manual
//! correction) into an entry without inventing missing fields.
//!
//! The crate depends on `lyra-reader-text` for the already-tested line/block layout rather than
//! reimplementing text extraction, and on `lyra-reader-core` only for the neutral DTOs. It does
//! not know about PDFium, Swift or the network.

pub mod bibtex;
pub mod recognize;

pub use bibtex::{BibEntry, BibEntryKind, escape_value, generate};
pub use recognize::{MetadataField, MetadataSource, RecognizedMetadata, recognize};
