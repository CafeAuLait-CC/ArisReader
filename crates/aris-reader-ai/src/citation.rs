//! Citation and figure index: **does not depend on AI**, pure structure/layout analysis (delivered in M4).
//!
//! Two layers of data sources (`docs/06-ai.md` §1):
//!
//! 1. **PDF link annotations** (reliable, but in many LaTeX papers `[12]` is not actually a link);
//! 2. **A self-built index**: locate the bibliography section → split it into entries → map patterns
//!    such as `[12]` / `Figure 3` in the body text to their target regions.
//!
//! Every candidate carries [`RefEntry::confidence`]: below the threshold (0.6 by default) it is not
//! registered as clickable — **better too few than wrong** (a false positive keeps disrupting reading).

use aris_reader_core::{Destination, PageIndex, Rect};

/// Citation label kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CitationKind {
    /// `[12]`, `[12,15]`, `[12–15]`
    Numeric,
    /// `(Smith et al., 2020)`
    AuthorYear,
    /// `Figure 3` / `Fig. 3`, or a localized (CJK) figure label followed by a number.
    /// The localized label sets are data, not prose: they land in M4 (T4.6).
    Figure,
    /// `Table 2`
    Table,
    /// `Eq. (5)` / equation `(5)`
    Equation,
    /// `§3.2` / `Section 3.2`
    Section,
    /// Footnote superscript number
    Footnote,
    /// PDF internal link annotation (the most reliable layer)
    LinkAnnotation,
}

/// Bibliography entry.
#[derive(Clone, Debug, PartialEq)]
pub struct RefEntry {
    /// Normalized label (`"12"` / `"smith2020"`).
    pub label: String,
    /// Raw text (the whole entry).
    pub text: String,
    /// Year of this author-year entry, if any.
    pub year: Option<u16>,
    pub authors: Option<String>,
    pub title: Option<String>,
    pub venue: Option<String>,
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    /// Location of the entry in the document.
    pub page: PageIndex,
    pub rect: Rect,
    /// Recognition confidence (0–1).
    pub confidence: f32,
}

/// Figure/table entry.
#[derive(Clone, Debug, PartialEq)]
pub struct FigureEntry {
    /// Normalized label (`"figure3"` / `"table2"`).
    pub label: String,
    pub kind: CitationKind,
    /// Raw caption text (shown at the bottom of the popover).
    pub caption: String,
    /// Figure/table region (caption included).
    pub page: PageIndex,
    pub rect: Rect,
    pub confidence: f32,
}

/// A resolved citation (used when building the AI context).
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedCitation {
    pub kind: CitationKind,
    pub label: String,
    pub text: String,
    pub page: PageIndex,
    pub rect: Rect,
}

/// Citation/figure index.
///
/// See `docs/06-ai.md` §2 for the build pipeline; cached to sidecar JSON under `(doc_hash, content_epoch)`,
/// so it is available within a second on the next open.
#[derive(Default, Debug, Clone, PartialEq)]
pub struct CitationIndex {
    pub references: Vec<RefEntry>,
    pub figures: Vec<FigureEntry>,
    /// Citation occurrences in the body text (body page → several clickable regions).
    pub spans: Vec<CitationSpan>,
}

/// A single citation occurrence in the body text.
#[derive(Clone, Debug, PartialEq)]
pub struct CitationSpan {
    /// Display text (such as `[12]`).
    pub text: String,
    pub kind: CitationKind,
    pub page: PageIndex,
    pub rect: Rect,
    /// Resolved target label (used to look back into [`CitationIndex::references`]).
    pub target_label: Option<String>,
    pub confidence: f32,
}

impl CitationIndex {
    pub fn new() -> Self {
        Self::default()
    }

    /// Candidates below this confidence are not registered as clickable.
    pub const MIN_CONFIDENCE: f32 = 0.6;

    pub fn is_empty(&self) -> bool {
        self.references.is_empty() && self.figures.is_empty() && self.spans.is_empty()
    }

    /// Look up a reference by label.
    pub fn reference(&self, label: &str) -> Option<&RefEntry> {
        self.references.iter().find(|r| r.label == label)
    }

    /// Look up a figure by label.
    pub fn figure(&self, label: &str) -> Option<&FigureEntry> {
        self.figures.iter().find(|f| f.label == label)
    }

    /// Resolve one citation occurrence → target location (used for popover navigation).
    ///
    /// `None` means it cannot be resolved (the UI must not render it as a link in that case).
    pub fn resolve(&self, span: &CitationSpan) -> Option<(Destination, ResolvedCitation)> {
        if span.confidence < Self::MIN_CONFIDENCE {
            return None;
        }
        let label = span.target_label.as_deref()?;

        if let Some(r) = self.reference(label) {
            return Some((
                Destination {
                    page: r.page,
                    view: aris_reader_core::DestView::FitR(r.rect),
                },
                ResolvedCitation {
                    kind: span.kind,
                    label: r.label.clone(),
                    text: r.text.clone(),
                    page: r.page,
                    rect: r.rect,
                },
            ));
        }

        if let Some(f) = self.figure(label) {
            return Some((
                Destination {
                    page: f.page,
                    view: aris_reader_core::DestView::FitR(f.rect),
                },
                ResolvedCitation {
                    kind: f.kind,
                    label: f.label.clone(),
                    text: f.caption.clone(),
                    page: f.page,
                    rect: f.rect,
                },
            ));
        }

        None
    }
}

/// Index builder (implemented in M4 T4.4–T4.6).
pub trait CitationIndexBuilder {
    /// Full build (runs in the background, does not block opening the document).
    fn build(&mut self) -> CitationIndex;

    /// Incremental update (after the document has been edited).
    fn update_page(&mut self, page: PageIndex) -> CitationIndex;
}
