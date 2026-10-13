//! Document data model: handles, pages, outline, links, and destinations.
//!
//! All of these types are **value-semantic snapshots** (safe to copy across the FFI boundary);
//! the actual document state is owned by the backend ([`crate::backend::DocumentBackend`]).

use crate::geometry::{PageGeometry, Rect};
use std::path::PathBuf;

/// Process-unique document identifier (assigned by the engine; not persisted across processes).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DocId(pub u64);

/// Page index (0-based, physical order).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PageIndex(pub u32);

impl PageIndex {
    pub fn get(self) -> u32 {
        self.0
    }
}

/// Information about a single page.
#[derive(Clone, Debug, PartialEq)]
pub struct PageInfo {
    pub index: PageIndex,
    pub geometry: PageGeometry,
    /// Page label (PDF `/PageLabels`, e.g. Roman-numeral front matter); `None` when there is no label.
    pub label: Option<String>,
}

/// Document metadata (an optional summary of `/Info` + XMP).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DocMetadata {
    pub title: Option<String>,
    pub author: Option<String>,
    pub subject: Option<String>,
    pub keywords: Option<String>,
    pub producer: Option<String>,
    /// ISO-8601 string (avoids passing a time type across FFI).
    pub creation_date: Option<String>,
}

/// Snapshot returned immediately after a document is opened (no page content or text).
#[derive(Clone, Debug, PartialEq)]
pub struct DocumentSnapshot {
    pub id: DocId,
    pub path: Option<PathBuf>,
    pub page_count: u32,
    pub metadata: DocMetadata,
    pub outline: Vec<OutlineNode>,
    pub is_encrypted: bool,
    /// Whether the document has a tagged structure (`FPDFCatalog_IsTagged`) — determines whether the structure tree can provide a reliable reading order.
    pub is_tagged: bool,
}

/// Outline node (bookmark tree).
#[derive(Clone, Debug, PartialEq)]
pub struct OutlineNode {
    pub title: String,
    pub dest: Option<Destination>,
    /// Page this node maps to (resolved from the destination, so the sidebar can follow the highlight).
    pub page: Option<PageIndex>,
    pub children: Vec<OutlineNode>,
}

/// Destination: page index + view mode (corresponds to PDF's `FPDFDest_GetView`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Destination {
    pub page: PageIndex,
    pub view: DestView,
}

/// PDF destination view mode.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum DestView {
    /// `/XYZ`: optional left/top coordinates and zoom
    Xyz {
        left: Option<f64>,
        top: Option<f64>,
        zoom: Option<f64>,
    },
    /// `/Fit`: fit the whole page
    Fit,
    /// `/FitH`: fit width
    FitH(Option<f64>),
    /// `/FitV`: fit height
    FitV(Option<f64>),
    /// `/FitR`: fit rectangle
    FitR(Rect),
    /// `/FitB`: fit the content bounding box
    FitB,
    FitBH(Option<f64>),
    FitBV(Option<f64>),
}

/// Link annotation (the first-layer data source for `docs/06-ai.md` §1).
#[derive(Clone, Debug, PartialEq)]
pub struct LinkInfo {
    /// Clickable area of the link (page coordinates in View/Page space).
    pub rect: Rect,
    /// Quadrilateral points (more accurate than the rectangle for rotated text).
    pub quads: Vec<Rect>,
    pub kind: LinkKind,
    /// Text the link displays on the page (when it can be obtained from the text layer), used for the popover title.
    pub text: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum LinkKind {
    /// Internal document jump (most references, figures, and table-of-contents entries go here).
    Internal(Destination),
    /// External URL.
    Uri(String),
    /// Open an external file.
    Launch(String),
    /// Other/unsupported action types.
    Unsupported,
}
