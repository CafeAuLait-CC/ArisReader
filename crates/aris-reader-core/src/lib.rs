//! ArisReader core crate: document model, coordinate geometry, and the PDF backend interface.
//!
//! **This crate and every `aris-*` engine crate must not depend on any platform types**
//! (no AppKit / Metal / window system). This is the first anti-corruption layer for
//! "port later without rewriting"; see `docs/adr/0001-native-ui-stack.md`.
//!
//! Layering:
//!
//! - [`geometry`]: the Page / View / Device coordinate systems and affine transforms (the Y flip happens only here)
//! - [`document`]: data model for documents, pages, outlines, links, and destinations
//! - [`backend`]: PDF engine interface (trait) plus rasterization requests/results, including **neutral DTOs**
//! - [`error`]: unified error type and error codes (mapped to Swift errors on the FFI side)
//! - [`config`]: engine configuration (cache budgets, concurrency, tile size, etc.)

pub mod backend;
pub mod config;
pub mod document;
pub mod error;
pub mod geometry;

pub use backend::{
    AnnotationAlignment, AnnotationBlend, AnnotationDrawing, AnnotationSkipReason, DocumentBackend,
    RasterFlags, RasterFormat, RasterRequest, RasterTile, RawAnnotation, RawAnnotationColor,
    RawAnnotationKind, RawAnnotationLine, RawCharBox, RawTextPage,
};
pub use config::{CacheBudget, EngineConfig};
pub use document::{
    DestView, Destination, DocId, DocMetadata, DocumentSnapshot, EmbeddedMetadata, LinkInfo,
    LinkKind, OutlineNode, PageIndex, PageInfo, XmpMetadata,
};
pub use error::{ArisError, ErrorCode, Result, Severity};
pub use geometry::{LineSegment, PageGeometry, Point, Rect, Rotation, Size, Transform2D};

/// Engine semantic version (tied to the interface stability of [`crate::backend`]).
pub const ENGINE_VERSION: &str = env!("CARGO_PKG_VERSION");
