//! Keyboard shortcut map — **defined in Rust**; the host only translates platform events into `(Key, Modifiers)`.
//!
//! This way the Windows/Linux shells can reuse the same bindings directly (only swapping ⌘ for Ctrl);
//! see `docs/04-ui-ux.md` §4 and `docs/adr/0001`.

/// Set of modifier keys.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Modifiers {
    /// macOS ⌘ / Windows·Linux Ctrl.
    pub primary: bool,
    pub shift: bool,
    pub alt: bool,
    /// macOS ⌃ (distinct from primary; used for a few system-level bindings).
    pub control: bool,
}

impl Modifiers {
    pub const NONE: Self = Self {
        primary: false,
        shift: false,
        alt: false,
        control: false,
    };
    pub const PRIMARY: Self = Self {
        primary: true,
        ..Self::NONE
    };
    pub const PRIMARY_SHIFT: Self = Self {
        primary: true,
        shift: true,
        ..Self::NONE
    };
    pub const PRIMARY_ALT: Self = Self {
        primary: true,
        alt: true,
        ..Self::NONE
    };
    pub const ALT: Self = Self {
        alt: true,
        ..Self::NONE
    };
    pub const SHIFT: Self = Self {
        shift: true,
        ..Self::NONE
    };
}

/// A key (excluding modifiers).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Key {
    Char(char),
    Left,
    Right,
    Up,
    Down,
    Space,
    Escape,
    Return,
    PageUp,
    PageDown,
    Home,
    End,
    Comma,
    Slash,
    Minus,
    Equal,
}

/// Semantic commands (corresponding to [`crate::Command`], but keeping only the parts that can be triggered from the keyboard).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CommandId {
    OpenFile,
    CloseTab,
    NewTab,
    ReopenTab,
    Save,
    SaveAs,
    NextPage,
    PrevPage,
    Back,
    Forward,
    ZoomIn,
    ZoomOut,
    ZoomActual,
    ZoomFitWidth,
    LayoutContinuous,
    LayoutSingle,
    LayoutFacing,
    ToggleSidebar,
    SidebarThumbnails,
    SidebarOutline,
    SidebarSearch,
    SidebarAi,
    Find,
    FindNext,
    FindPrev,
    FindSelection,
    ToolSelect,
    ToolHighlight,
    ToolUnderline,
    ToolStrikeOut,
    ToolNote,
    ToolInk,
    ToolText,
    Undo,
    Redo,
    AiPanel,
    ExplainSelection,
    TranslateSelection,
    PreviewCitation,
    ToggleFullScreen,
    ToggleChrome,
    ShortcutHelp,
    Settings,
}

/// One binding.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyBinding {
    pub key: Key,
    pub mods: Modifiers,
    pub command: CommandId,
}

/// Default keymap (`docs/04-ui-ux.md` §4).
pub fn default_keymap() -> Vec<KeyBinding> {
    use CommandId::*;
    use Key::*;
    use Modifiers as M;

    let b = |key: Key, mods: Modifiers, command: CommandId| KeyBinding { key, mods, command };

    vec![
        // File
        b(Char('o'), M::PRIMARY, OpenFile),
        b(Char('w'), M::PRIMARY, CloseTab),
        b(Char('t'), M::PRIMARY, NewTab),
        b(Char('t'), M::PRIMARY_SHIFT, ReopenTab),
        b(Char('s'), M::PRIMARY, Save),
        b(Char('s'), M::PRIMARY_SHIFT, SaveAs),
        // Navigation
        b(Left, M::PRIMARY, PrevPage),
        b(Right, M::PRIMARY, NextPage),
        b(Char('['), M::PRIMARY, Back),
        b(Char(']'), M::PRIMARY, Forward),
        b(Space, M::NONE, NextPage),
        b(Space, M::SHIFT, PrevPage),
        // Zoom
        b(Equal, M::PRIMARY, ZoomIn),
        b(Minus, M::PRIMARY, ZoomOut),
        b(Char('0'), M::PRIMARY, ZoomActual),
        b(Char('9'), M::PRIMARY, ZoomFitWidth),
        // Layout
        b(Char('1'), M::PRIMARY, LayoutContinuous),
        b(Char('2'), M::PRIMARY, LayoutSingle),
        b(Char('3'), M::PRIMARY, LayoutFacing),
        b(Char('s'), M::PRIMARY_ALT, ToggleSidebar),
        b(Char('1'), M::PRIMARY_ALT, SidebarThumbnails),
        b(Char('2'), M::PRIMARY_ALT, SidebarOutline),
        b(Char('5'), M::PRIMARY_ALT, SidebarSearch),
        b(Char('6'), M::PRIMARY_ALT, SidebarAi),
        // Search
        b(Char('f'), M::PRIMARY, Find),
        b(Char('g'), M::PRIMARY, FindNext),
        b(Char('g'), M::PRIMARY_SHIFT, FindPrev),
        b(Char('e'), M::PRIMARY, FindSelection),
        // Annotation tools (M3)
        b(Char('v'), M::NONE, ToolSelect),
        b(Char('h'), M::NONE, ToolHighlight),
        b(Char('u'), M::NONE, ToolUnderline),
        b(Char('s'), M::NONE, ToolStrikeOut),
        b(Char('n'), M::NONE, ToolNote),
        b(Char('i'), M::NONE, ToolInk),
        b(Char('t'), M::NONE, ToolText),
        b(Char('z'), M::PRIMARY, Undo),
        b(Char('z'), M::PRIMARY_SHIFT, Redo),
        // AI and advanced reading (M4/M5)
        b(Char('a'), M::PRIMARY_SHIFT, AiPanel),
        b(Char('r'), M::PRIMARY_SHIFT, ExplainSelection),
        // Note: ⌘⇧T is already taken by "reopen closed tab", so translation uses ⌘⇧L (Language)
        b(Char('l'), M::PRIMARY_SHIFT, TranslateSelection),
        b(Char('p'), M::PRIMARY_SHIFT, PreviewCitation),
        // View
        b(Char('f'), M::PRIMARY_ALT, ToggleFullScreen),
        b(Char('h'), M::PRIMARY_ALT, ToggleChrome),
        b(Slash, M::PRIMARY, ShortcutHelp),
        b(Comma, M::PRIMARY, Settings),
    ]
}

/// Lookup.
pub fn lookup(map: &[KeyBinding], key: Key, mods: Modifiers) -> Option<CommandId> {
    map.iter()
        .find(|b| b.key == key && b.mods == mods)
        .map(|b| b.command)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn common_shortcuts_resolve() {
        let map = default_keymap();
        assert_eq!(
            lookup(&map, Key::Char('f'), Modifiers::PRIMARY),
            Some(CommandId::Find)
        );
        assert_eq!(
            lookup(&map, Key::Equal, Modifiers::PRIMARY),
            Some(CommandId::ZoomIn)
        );
        assert_eq!(
            lookup(&map, Key::Space, Modifiers::NONE),
            Some(CommandId::NextPage)
        );
        assert_eq!(
            lookup(&map, Key::Char('p'), Modifiers::PRIMARY_SHIFT),
            Some(CommandId::PreviewCitation)
        );
    }

    #[test]
    fn modifiers_matter() {
        let map = default_keymap();
        // ⌘F is find; a bare F is nothing
        assert_eq!(lookup(&map, Key::Char('f'), Modifiers::NONE), None);
    }

    #[test]
    fn no_duplicate_bindings() {
        let map = default_keymap();
        for (i, a) in map.iter().enumerate() {
            for b in &map[i + 1..] {
                assert!(
                    !(a.key == b.key && a.mods == b.mods),
                    "duplicate binding: {:?} {:?}",
                    a.key,
                    a.mods
                );
            }
        }
    }
}
