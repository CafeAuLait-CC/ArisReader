//! Session layer: a **platform-independent reading state machine**.
//!
//! This is the second anti-corruption layer for "port later without rewriting" (`docs/adr/0001`): scroll anchoring, zoom math,
//! layout, page turning, navigation history, and the keymap all live here; the Swift/GTK/WinUI shells do only two things —
//! **translate UI events into [`Command`]s** and **render [`Event`]s into widgets**.
//!
//! Task mapping: T1.8 (viewport/layout/anchoring), T2.8 (history), T1.4 (scroll approach decision).

pub mod command;
pub mod keymap;
pub mod layout;
pub mod viewport;

pub use command::{Anchor, Command, Event, Layout, Zoom};
pub use keymap::{CommandId, Key, KeyBinding, Modifiers, default_keymap, lookup};
pub use layout::{DocumentLayout, PagePlacement};
pub use viewport::{Viewport, resolve_zoom};

use aris_reader_core::{Destination, DocId, PageIndex, Rect, Size};

/// Navigation history (back/forward).
///
/// `cursor` points at **the entry currently being viewed**; `push` discards the forward branch
/// after the current position (matching browser behavior).
#[derive(Default)]
struct NavHistory {
    entries: Vec<Destination>,
    cursor: usize,
}

impl NavHistory {
    fn push(&mut self, dest: Destination) {
        self.entries.truncate(self.cursor + 1);
        self.entries.push(dest);
        self.cursor = self.entries.len().saturating_sub(1);
    }

    fn back(&mut self) -> Option<Destination> {
        if self.entries.is_empty() || self.cursor == 0 {
            return None;
        }
        self.cursor -= 1;
        self.entries.get(self.cursor).copied()
    }

    fn forward(&mut self) -> Option<Destination> {
        if self.entries.is_empty() || self.cursor + 1 >= self.entries.len() {
            return None;
        }
        self.cursor += 1;
        self.entries.get(self.cursor).copied()
    }
}

/// A reading session (one reading in one tab/window).
///
/// During the skeleton phase events are buffered in a `Vec`; the real implementation will push them to the host over a channel
/// (see the backpressure strategy in `docs/02-architecture.md` §5).
pub struct Session {
    doc: DocId,
    viewport: Viewport,
    history: NavHistory,
    epoch: u64,
    pending: Vec<Event>,
}

impl Session {
    pub fn new(doc: DocId, viewport: Viewport) -> Self {
        Self {
            doc,
            viewport,
            history: NavHistory::default(),
            epoch: 0,
            pending: Vec::new(),
        }
    }

    pub fn doc(&self) -> DocId {
        self.doc
    }

    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    pub fn viewport(&self) -> &Viewport {
        &self.viewport
    }

    /// Take the events pending delivery (called by the host once per frame).
    pub fn drain_events(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.pending)
    }

    /// Execute a command. Returns **immediately**; results are published as events.
    pub fn execute(&mut self, command: Command) {
        match command {
            Command::SetZoom(zoom) => {
                self.viewport.zoom = zoom;
                self.bump_viewport();
            }
            Command::SetLayout(layout) => {
                self.viewport.layout = layout;
                self.bump_viewport();
            }
            Command::ScrollTo { page, anchor } => {
                self.bump_viewport();
                self.pending.push(Event::ScrollToRequested { page, anchor });
            }
            Command::GotoDestination(dest) => {
                self.history.push(dest);
                self.bump_viewport();
                self.pending.push(Event::Navigated { dest });
            }
            Command::GoBack => {
                if let Some(dest) = self.history.back() {
                    self.bump_viewport();
                    self.pending.push(Event::Navigated { dest });
                }
            }
            Command::GoForward => {
                if let Some(dest) = self.history.forward() {
                    self.bump_viewport();
                    self.pending.push(Event::Navigated { dest });
                }
            }
            Command::OpenFloatingPreview { target, .. } => {
                // M4: the render layer reuses the tile cache for the floating preview content, then pushes FloatingPreviewReady
                self.pending
                    .push(Event::FloatingPreviewRequested { target });
            }
            other => {
                self.pending.push(Event::CommandIgnored {
                    reason: format!("{other:?} is not implemented yet (skeleton phase)"),
                });
            }
        }
    }

    /// Viewport change entry point (scrolling/zooming/window resize all go through here).
    pub fn set_viewport(&mut self, rect: Rect, zoom_factor: f64, backing_scale: f64) {
        self.viewport.scroll = rect.origin;
        self.viewport.view_size = rect.size;
        self.viewport.zoom_factor = zoom_factor;
        self.viewport.backing_scale = backing_scale;
        self.bump_viewport();
    }

    /// Report after each frame has been composited (debug statistics).
    pub fn on_frame_presented(&mut self, frame_ms: f32) {
        self.pending.push(Event::FramePresented { frame_ms });
    }

    fn bump_viewport(&mut self) {
        self.epoch += 1;
        self.pending.push(Event::ViewportChanged {
            epoch: self.epoch,
            page: self.nearest_page_hint(),
            zoom_factor: self.viewport.zoom_factor,
        });
    }

    /// TODO(T1.8): derive the "current page" from the Layout's page-offset prefix sums with a binary search.
    fn nearest_page_hint(&self) -> PageIndex {
        PageIndex(0)
    }

    pub fn visible_size(&self) -> Size {
        self.viewport.visible_rect().size
    }

    /// Device pixel scale used by the render layer to request tiles.
    pub fn required_raster_scale(&self) -> f64 {
        self.viewport.device_scale()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use aris_reader_core::DestView;

    fn dest(page: u32) -> Destination {
        Destination {
            page: PageIndex(page),
            view: DestView::Fit,
        }
    }

    fn session() -> Session {
        Session::new(DocId(1), Viewport::default())
    }

    #[test]
    fn navigation_history_back_and_forward() {
        let mut s = session();
        s.execute(Command::GotoDestination(dest(1)));
        s.execute(Command::GotoDestination(dest(2)));
        let _ = s.drain_events();

        s.execute(Command::GoBack);
        let events = s.drain_events();
        // going back emits ViewportChanged first (the epoch is bumped), then Navigated
        assert!(
            matches!(events.last(), Some(Event::Navigated { dest }) if dest.page == PageIndex(1)),
            "events = {events:?}"
        );
        assert!(
            events
                .iter()
                .any(|e| matches!(e, Event::ViewportChanged { .. }))
        );

        s.execute(Command::GoForward);
        let events = s.drain_events();
        assert!(
            matches!(events.last(), Some(Event::Navigated { dest }) if dest.page == PageIndex(2)),
            "events = {events:?}"
        );
    }

    #[test]
    fn history_truncates_after_back_then_new_navigation() {
        let mut s = session();
        s.execute(Command::GotoDestination(dest(1)));
        s.execute(Command::GotoDestination(dest(2)));
        s.execute(Command::GoBack);
        s.execute(Command::GotoDestination(dest(5))); // new branch, discards (2)
        let _ = s.drain_events(); // drain the events produced by the preceding commands

        s.execute(Command::GoForward);
        assert!(
            s.drain_events().is_empty(),
            "forward history should have been truncated"
        );
    }

    #[test]
    fn viewport_change_bumps_epoch() {
        let mut s = session();
        let e0 = s.epoch();
        s.set_viewport(Rect::new(0.0, 0.0, 800.0, 600.0), 1.0, 2.0);
        assert_eq!(s.epoch(), e0 + 1);
        assert!((s.required_raster_scale() - 2.0).abs() < 1e-9);
    }
}
