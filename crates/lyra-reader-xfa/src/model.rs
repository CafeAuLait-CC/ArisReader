//! Value model shared by the template reader, the layout engine and the report.

use crate::units::{Color, length};
use std::collections::BTreeMap;

/// Where a node sits and how much room it asks for. Missing width and height are meaningful:
/// an absent height is "as tall as the content" and a zero height is a rule.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Geometry {
    pub x: f64,
    pub y: f64,
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub min_height: Option<f64>,
    pub max_height: Option<f64>,
}

impl Geometry {
    pub fn from_attributes(attributes: &BTreeMap<String, String>) -> Self {
        Self {
            x: length(attributes.get("x").map(String::as_str)).unwrap_or(0.0),
            y: length(attributes.get("y").map(String::as_str)).unwrap_or(0.0),
            width: length(attributes.get("w").map(String::as_str)),
            height: length(attributes.get("h").map(String::as_str)),
            min_height: length(attributes.get("minH").map(String::as_str)),
            max_height: length(attributes.get("maxH").map(String::as_str)),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Insets {
    pub top: f64,
    pub bottom: f64,
    pub left: f64,
    pub right: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum HorizontalAlign {
    #[default]
    Left,
    Center,
    Right,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum VerticalAlign {
    #[default]
    Top,
    Middle,
    Bottom,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Paragraph {
    pub horizontal: HorizontalAlign,
    pub vertical: VerticalAlign,
    pub space_above: f64,
    pub space_below: f64,
    pub text_indent: f64,
    pub margin_left: f64,
    pub margin_right: f64,
    pub line_height: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TextStyle {
    pub typeface: Option<String>,
    pub size: f64,
    pub bold: bool,
    pub italic: bool,
    pub color: Color,
}

impl Default for TextStyle {
    fn default() -> Self {
        Self {
            typeface: None,
            size: 7.0,
            bold: false,
            italic: false,
            color: Color::BLACK,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Border {
    /// At least one edge is visible.
    pub visible: bool,
    pub thickness: f64,
    pub color: Color,
    pub fill: Option<Color>,
    /// Top, right, bottom, left; an absent stroke is an explicitly hidden edge.
    pub edges: [Option<(f64, Color)>; 4],
}

impl Default for Border {
    fn default() -> Self {
        Self {
            visible: false,
            thickness: 0.5,
            color: Color::BLACK,
            fill: None,
            edges: [None; 4],
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptionPlacement {
    Top,
    Bottom,
    Left,
    Right,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Caption {
    pub text: String,
    pub rich: Vec<RichParagraph>,
    pub placement: Option<CaptionPlacement>,
    pub reserve: f64,
    pub style: TextStyle,
    pub paragraph: Paragraph,
    pub margins: Insets,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Presence {
    #[default]
    Visible,
    Invisible,
    Hidden,
}

impl Presence {
    pub fn parse(value: Option<&str>) -> Self {
        match value.unwrap_or("").trim().to_ascii_lowercase().as_str() {
            "hidden" => Self::Hidden,
            "invisible" => Self::Invisible,
            _ => Self::Visible,
        }
    }

    /// Whether the node occupies layout space.
    pub fn occupies_space(self) -> bool {
        !matches!(self, Self::Hidden)
    }

    /// Whether the node paints.
    pub fn paints(self) -> bool {
        matches!(self, Self::Visible)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LayoutKind {
    Position,
    TopBottom,
    LeftRightTopBottom,
    Table,
    Row,
    /// A layout keyword this reader does not implement; the node is laid out as `Position`.
    Unsupported(String),
}

impl LayoutKind {
    pub fn parse(value: Option<&str>) -> Self {
        match value.unwrap_or("").trim().to_ascii_lowercase().as_str() {
            "" | "position" | "absolute" => Self::Position,
            "tb" | "top-to-bottom" => Self::TopBottom,
            "lr-tb" | "left-to-right" => Self::LeftRightTopBottom,
            "table" => Self::Table,
            "row" => Self::Row,
            other => Self::Unsupported(other.to_string()),
        }
    }

    pub fn label(&self) -> &str {
        match self {
            Self::Position => "position",
            Self::TopBottom => "tb",
            Self::LeftRightTopBottom => "lr-tb",
            Self::Table => "table",
            Self::Row => "row",
            Self::Unsupported(value) => value,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FieldType {
    Text,
    CheckButton,
    Choice,
    DateTime,
    Numeric,
    Button,
    Barcode,
    Signature,
    Picture,
    Unknown,
}

impl FieldType {
    pub fn label(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::CheckButton => "checkButton",
            Self::Choice => "choiceList",
            Self::DateTime => "dateTimeEdit",
            Self::Numeric => "numericEdit",
            Self::Button => "button",
            Self::Barcode => "barcode",
            Self::Signature => "signature",
            Self::Picture => "picture",
            Self::Unknown => "unknown",
        }
    }

    /// Types this renderer draws as a box with text and a caption.
    pub fn is_textual(self) -> bool {
        matches!(
            self,
            Self::Text | Self::DateTime | Self::Numeric | Self::Choice
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct FieldInfo {
    pub kind: FieldType,
    pub default_value: Option<String>,
    pub default_rich: Vec<RichParagraph>,
    pub items: Vec<String>,
    pub item_values: Vec<String>,
    pub bind_items: Option<String>,
    pub read_only: bool,
    pub multiline: bool,
    pub checked: bool,
    pub round_check: bool,
}

impl Default for FieldInfo {
    fn default() -> Self {
        Self {
            kind: FieldType::Unknown,
            default_value: None,
            default_rich: Vec::new(),
            items: Vec::new(),
            item_values: Vec::new(),
            bind_items: None,
            read_only: false,
            multiline: false,
            checked: false,
            round_check: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RichRun {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub size: Option<f64>,
    pub color: Option<Color>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RichParagraph {
    pub runs: Vec<RichRun>,
    pub horizontal: Option<HorizontalAlign>,
}

impl RichParagraph {
    pub fn text(&self) -> String {
        self.runs.iter().map(|run| run.text.as_str()).collect()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum DrawKind {
    Text,
    Line {
        thickness: f64,
    },
    Rectangle {
        filled: bool,
    },
    Image {
        content_type: String,
        bytes: Vec<u8>,
    },
    /// A value element this reader knows it cannot paint.
    Unsupported(String),
}

impl DrawKind {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Line { .. } => "line",
            Self::Rectangle { .. } => "rectangle",
            Self::Image { .. } => "image",
            Self::Unsupported(_) => "unsupported",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DrawInfo {
    pub kind: DrawKind,
    pub text: String,
    pub rich: Vec<RichParagraph>,
}

impl Default for DrawInfo {
    fn default() -> Self {
        Self {
            kind: DrawKind::Text,
            text: String::new(),
            rich: Vec::new(),
        }
    }
}

/// One node of the template tree that affects layout or painting.
#[derive(Clone, Debug, PartialEq)]
pub struct LayoutNode {
    pub kind: NodeKind,
    pub name: String,
    pub geometry: Geometry,
    pub presence: Presence,
    pub relevant: Option<String>,
    pub layout: LayoutKind,
    pub column_widths: Vec<f64>,
    pub font: TextStyle,
    pub paragraph: Paragraph,
    pub margins: Insets,
    pub border: Border,
    pub caption: Option<Caption>,
    pub field: Option<FieldInfo>,
    pub draw: Option<DrawInfo>,
    pub children: Vec<LayoutNode>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NodeKind {
    Subform,
    Field,
    Draw,
    ExclGroup,
}

impl NodeKind {
    pub fn label(self) -> &'static str {
        match self {
            Self::Subform => "subform",
            Self::Field => "field",
            Self::Draw => "draw",
            Self::ExclGroup => "exclGroup",
        }
    }
}

impl LayoutNode {
    pub fn is_hidden_for_print(&self) -> bool {
        !self.presence.occupies_space() || self.is_irrelevant_for_print()
    }

    pub fn is_irrelevant_for_print(&self) -> bool {
        self.relevant
            .as_deref()
            .is_some_and(|value| value.trim_start().starts_with('-') && value.contains("print"))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PageSize {
    pub width: f64,
    pub height: f64,
}

impl PageSize {
    pub const LETTER: Self = Self {
        width: 612.0,
        height: 792.0,
    };
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ContentArea {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug)]
pub struct PageArea {
    pub name: String,
    pub page_size: PageSize,
    pub content_area: ContentArea,
    pub children: Vec<LayoutNode>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PageBreak {
    pub target_type: Option<String>,
    pub target: Option<String>,
    pub start_new: bool,
    pub before: bool,
}

#[derive(Clone, Debug)]
pub struct PageTemplate {
    pub name: String,
    pub break_before: Option<PageBreak>,
    pub break_after: Option<PageBreak>,
    pub node: LayoutNode,
}

#[derive(Clone, Debug, Default)]
pub struct FontUsage {
    pub typeface: String,
    pub counts: BTreeMap<u32, usize>,
}

impl FontUsage {
    pub fn add(&mut self, size: f64) {
        let key = (size * 10.0).round().max(0.0) as u32;
        *self.counts.entry(key).or_default() += 1;
    }

    pub fn sizes(&self) -> Vec<f64> {
        self.counts
            .keys()
            .map(|tenths| f64::from(*tenths) / 10.0)
            .collect()
    }

    /// Number of nodes that use this typeface.
    pub fn uses(&self) -> usize {
        self.counts.values().sum()
    }
}
