//! Edit layer: annotation model, undo stack, page operations and save policies.
//!
//! Task mapping: T3.1 (model + undo stack), T3.7 (incremental save), T3.9 (page operations).
//!
//! # Design notes
//!
//! - Annotations are **written to the in-memory model first** (rendered immediately, no UI wait);
//!   the backend writes them into the PDF only on save.
//! - Every successful edit increments `content_epoch`, which invalidates the cached tiles
//!   (see `docs/03-rendering.md` §6).
//! - Saving uses **incremental save** by default (append-only writes): the original bytes are not
//!   rewritten, so an existing digital signature stays valid.

use aris_reader_core::{DocId, PageIndex, Rect};

/// Annotation identifier (unique within the process; after saving it maps to the PDF object number).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct AnnotationId(pub u64);

/// Annotation kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnnotationKind {
    Highlight,
    Underline,
    StrikeOut,
    Squiggly,
    Ink,
    Square,
    Circle,
    Line,
    Arrow,
    FreeText,
    Note,
    Stamp,
}

/// Annotation (neutral model, independent of any backend).
#[derive(Clone, Debug, PartialEq)]
pub struct Annotation {
    pub id: AnnotationId,
    pub page: PageIndex,
    pub kind: AnnotationKind,
    /// Bounding box in page coordinates (the outer box for Ink).
    pub rect: Rect,
    /// Baseline quads of a text annotation (highlights/underlines are drawn along them).
    pub quads: Vec<Rect>,
    /// RGBA color.
    pub color: [u8; 4],
    /// Opacity (0–1).
    pub opacity: f64,
    pub contents: Option<String>,
    pub author: Option<String>,
    /// Creation time (millisecond timestamp; passed as an integer across the FFI).
    pub created_at_ms: i64,
    /// Ink strokes of an Ink annotation (each stroke is a sequence of page-coordinate points).
    pub ink_paths: Vec<Vec<aris_reader_core::Point>>,
}

/// Edit operation (also an element of the undo stack).
#[derive(Clone, Debug, PartialEq)]
pub enum EditOp {
    /// Add an annotation (the real id must be backfilled after saving).
    AddAnnotation(Annotation),
    RemoveAnnotation(AnnotationId),
    /// Change one aspect of an annotation (simplified to a whole-value replacement so undo stays easy).
    ReplaceAnnotation {
        before: Annotation,
        after: Annotation,
    },
    RotatePages {
        pages: Vec<PageIndex>,
        degrees: i32,
    },
    DeletePages(Vec<PageIndex>),
    MovePage {
        from: PageIndex,
        to: PageIndex,
    },
    InsertBlankPage {
        at: PageIndex,
    },
}

/// Edit transaction: a sequence of operations plus the undo/redo stacks.
///
/// TODO(T3.1): coordinate with the backend (apply/rollback) and broadcast `content_epoch` changes to the render layer.
#[derive(Default)]
pub struct EditHistory {
    undo_stack: Vec<EditOp>,
    redo_stack: Vec<EditOp>,
}

impl EditHistory {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record an already applied operation (clears the redo stack).
    pub fn push(&mut self, op: EditOp) {
        self.redo_stack.clear();
        self.undo_stack.push(op);
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    /// Pop the operation to undo (the caller performs the actual rollback).
    pub fn undo(&mut self) -> Option<EditOp> {
        let op = self.undo_stack.pop()?;
        self.redo_stack.push(op.clone());
        Some(op)
    }

    /// Pop the operation to redo (the caller performs the actual application).
    pub fn redo(&mut self) -> Option<EditOp> {
        let op = self.redo_stack.pop()?;
        self.undo_stack.push(op.clone());
        Some(op)
    }

    pub fn len(&self) -> usize {
        self.undo_stack.len()
    }

    pub fn is_empty(&self) -> bool {
        self.undo_stack.is_empty()
    }
}

/// Save policy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SavePolicy {
    /// Incremental save (append), keeps signatures valid — the default.
    Incremental,
    /// Full rewrite (drops garbage objects, shrinks the file), invalidates existing signatures.
    FullRewrite,
    /// Save as a new file (the original file is left untouched).
    SaveAsNewFile,
}

/// Save result.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SaveOutcome {
    pub doc: DocId,
    pub appended_bytes: u64,
    pub policy: SavePolicy,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(id: u64) -> Annotation {
        Annotation {
            id: AnnotationId(id),
            page: PageIndex(0),
            kind: AnnotationKind::Highlight,
            rect: Rect::new(0.0, 0.0, 10.0, 10.0),
            quads: Vec::new(),
            color: [255, 235, 59, 128],
            opacity: 1.0,
            contents: None,
            author: None,
            created_at_ms: 0,
            ink_paths: Vec::new(),
        }
    }

    #[test]
    fn undo_redo_roundtrip() {
        let mut h = EditHistory::new();
        assert!(!h.can_undo() && !h.can_redo());

        h.push(EditOp::AddAnnotation(sample(1)));
        h.push(EditOp::AddAnnotation(sample(2)));
        assert_eq!(h.len(), 2);

        let undone = h.undo().expect("undo");
        assert_eq!(undone, EditOp::AddAnnotation(sample(2)));
        assert!(h.can_redo());

        let redone = h.redo().expect("redo");
        assert_eq!(redone, EditOp::AddAnnotation(sample(2)));
        assert!(!h.can_redo());
    }

    #[test]
    fn push_clears_redo_stack() {
        let mut h = EditHistory::new();
        h.push(EditOp::DeletePages(vec![PageIndex(1)]));
        let _ = h.undo();
        assert!(h.can_redo());
        h.push(EditOp::InsertBlankPage { at: PageIndex(0) });
        assert!(!h.can_redo());
    }
}
