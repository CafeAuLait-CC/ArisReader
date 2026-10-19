//! Commands and events: the only interface surface between the host (Swift/GTK/WinUI) and the engine.
//!
//! Conventions (`docs/02-architecture.md` §5):
//!
//! - **Commands are asynchronous**: `execute()` returns immediately and results are published as events;
//! - **Events carry an epoch**: the host must discard stale events (especially important while fast scrolling);
//! - **Events may be coalesced**: when the channel is full, only the newest event of a kind is kept (backpressure does not block the producer).

use lyra_reader_core::{Destination, DocId, PageIndex, Point, Rect};

/// Zoom mode.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Zoom {
    /// Fixed factor (1.0 = 100%).
    Factor(f64),
    FitWidth,
    FitPage,
    FitHeight,
    /// Actual size (100%).
    Actual,
}

impl Default for Zoom {
    fn default() -> Self {
        Self::Factor(1.0)
    }
}

/// Page layout mode.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Layout {
    /// Continuous scrolling (default).
    #[default]
    Continuous,
    /// Single page.
    SinglePage,
    /// Two-page spread.
    Facing,
    /// Two-page spread with a standalone first page (common for books/papers).
    FacingFirstCover,
}

/// Jump anchor: the relative position of the target point within the viewport.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Anchor {
    /// Align the page top with the viewport top.
    Top,
    Center,
    Bottom,
    /// Place the page point at the viewport point (used for anchored zooming and floating previews).
    Point {
        page: Point,
        view: Point,
    },
}

/// Engine commands (host → engine).
#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    OpenDocument {
        path: std::path::PathBuf,
        password: Option<String>,
    },
    CloseDocument {
        id: DocId,
    },
    SetLayout(Layout),
    SetZoom(Zoom),
    ScrollTo {
        page: PageIndex,
        anchor: Anchor,
    },
    /// Jump to a destination (outline/link/search hit).
    GotoDestination(Destination),
    GoBack,
    GoForward,
    /// Request a floating preview of a target (M4: citations/figures).
    OpenFloatingPreview {
        target: Destination,
        at: Point,
    },
    CloseFloatingPreview {
        id: u64,
    },
    /// Incremental save (M3).
    SaveDocument,
    /// Undo/redo (M3).
    Undo,
    Redo,
}

/// Engine events (engine → host).
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// The viewport changed (the host updates the scroll position and redraws accordingly).
    ViewportChanged {
        epoch: u64,
        page: PageIndex,
        zoom_factor: f64,
    },
    /// The engine asks the host to scroll to the given position.
    ScrollToRequested { page: PageIndex, anchor: Anchor },
    /// Navigation completed (history has been updated).
    Navigated { dest: Destination },
    /// Floating preview content is ready (the render layer has drawn the target region into the corresponding surface).
    FloatingPreviewRequested { target: Destination },
    /// A frame has been presented (debug statistics).
    FramePresented { frame_ms: f32 },
    /// The command was not handled (skeleton-phase placeholder; must not occur in the real implementation).
    CommandIgnored { reason: String },
}

/// Serializable viewport snapshot (for passing across FFI).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ViewportSnapshot {
    pub scroll: Point,
    pub view_size: lyra_reader_core::Size,
    pub zoom_factor: f64,
    pub device_scale: f64,
    pub layout: Layout,
    /// Viewport rectangle (View Space).
    pub visible: Rect,
    pub epoch: u64,
}
