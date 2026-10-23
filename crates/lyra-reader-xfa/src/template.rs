//! The XFA template packet: pages, subforms, fields, static draws and the style the layout
//! engine needs. This is a reader, not a validator: an element it cannot place is kept in
//! `warnings` and skipped, so the rest of the form still renders.

use crate::error::{Result, XfaError};
use crate::model::*;
use crate::units::{Color, length, normalise_space};
use crate::xml::{Element, parse as parse_xml};
use std::collections::{BTreeMap, BTreeSet};

/// Parsed template plus the derived facts the report and layout need.
#[derive(Clone, Debug)]
pub struct Template {
    pub root: LayoutNode,
    pub pages: Vec<PageTemplate>,
    pub page_areas: Vec<PageArea>,
    pub fonts: BTreeMap<String, FontUsage>,
    pub warnings: Vec<String>,
    pub has_xdp_wrapper: bool,
    pub script_count: usize,
    pub event_count: usize,
}

/// One field for the structural report.
#[derive(Clone, Debug)]
pub struct FieldRecord {
    pub page: usize,
    pub path: String,
    pub kind: FieldType,
    pub geometry: Geometry,
    pub presence: Presence,
    pub caption: Option<String>,
    pub value: Option<String>,
    pub read_only: bool,
}

/// One static draw for the structural report.
#[derive(Clone, Debug)]
pub struct DrawRecord {
    pub page: usize,
    pub path: String,
    pub kind: &'static str,
    pub geometry: Geometry,
    pub text: Option<String>,
}

impl Template {
    pub fn fields(&self) -> Vec<FieldRecord> {
        let mut records = Vec::new();
        for (page, template) in self.pages.iter().enumerate() {
            collect_fields(page, &template.node, &template.name, &mut records);
        }
        records
    }

    pub fn draws(&self) -> Vec<DrawRecord> {
        let mut records = Vec::new();
        for (page, template) in self.pages.iter().enumerate() {
            collect_draws(page, &template.node, &template.name, &mut records);
        }
        records
    }

    pub fn field_type_counts(&self) -> BTreeMap<&'static str, usize> {
        let mut counts = BTreeMap::new();
        for field in self.fields() {
            *counts.entry(field.kind.label()).or_insert(0) += 1;
        }
        counts
    }

    pub fn page_breaks(&self) -> Vec<(String, Option<PageBreak>)> {
        self.pages
            .iter()
            .map(|page| (page.name.clone(), page.break_before.clone()))
            .collect()
    }
}

fn collect_fields(page: usize, node: &LayoutNode, path: &str, records: &mut Vec<FieldRecord>) {
    if node.kind == NodeKind::Field {
        records.push(FieldRecord {
            page,
            path: path.to_string(),
            kind: node
                .field
                .as_ref()
                .map(|field| field.kind)
                .unwrap_or(FieldType::Unknown),
            geometry: node.geometry,
            presence: node.presence,
            caption: node.caption.as_ref().map(|caption| caption.text.clone()),
            value: node
                .field
                .as_ref()
                .and_then(|field| field.default_value.clone()),
            read_only: node.field.as_ref().is_some_and(|field| field.read_only),
        });
    }
    let mut seen: BTreeMap<&str, usize> = BTreeMap::new();
    for child in &node.children {
        let count = seen.entry(child.name.as_str()).or_insert(0);
        let index = *count;
        *count += 1;
        let child_path = if child.name.is_empty() {
            format!("{path}[{index}]")
        } else {
            format!("{path}.{}[{index}]", child.name)
        };
        collect_fields(page, child, &child_path, records);
    }
}

fn collect_draws(page: usize, node: &LayoutNode, path: &str, records: &mut Vec<DrawRecord>) {
    if node.kind == NodeKind::Draw {
        records.push(DrawRecord {
            page,
            path: path.to_string(),
            kind: node
                .draw
                .as_ref()
                .map(|draw| draw.kind.label())
                .unwrap_or("draw"),
            geometry: node.geometry,
            text: node.draw.as_ref().and_then(|draw| {
                if draw.text.trim().is_empty() {
                    None
                } else {
                    Some(draw.text.trim().to_string())
                }
            }),
        });
    }
    let mut seen: BTreeMap<&str, usize> = BTreeMap::new();
    for child in &node.children {
        let count = seen.entry(child.name.as_str()).or_insert(0);
        let index = *count;
        *count += 1;
        let child_path = format!("{path}.{}[{index}]", child.name);
        collect_draws(page, child, &child_path, records);
    }
}

/// Parse the template packet. `bytes` may be a bare `<template>` packet or a whole XDP that
/// contains one.
pub fn parse_template(bytes: &[u8]) -> Result<Template> {
    let text = String::from_utf8_lossy(bytes);
    let document = parse_xml(&text)
        .ok_or_else(|| XfaError::Malformed("the template packet is not XML".to_string()))?;
    let has_xdp_wrapper = document.name.eq_ignore_ascii_case("xdp");
    let template = if document.name.eq_ignore_ascii_case("template") {
        document
    } else {
        document
            .find("template")
            .cloned()
            .ok_or_else(|| XfaError::Malformed("the XDP has no <template> packet".to_string()))?
    };
    let mut warnings = Vec::new();
    let root_element = template
        .elements()
        .find(|element| element.name.eq_ignore_ascii_case("subform"))
        .or_else(|| template.elements().next())
        .ok_or_else(|| XfaError::Malformed("the template has no root subform".to_string()))?;

    let defaults = Defaults::default();
    let root = build_node(root_element, &defaults, &mut warnings);

    let (page_areas, pages) = parse_pages(root_element, &root, &mut warnings);

    let mut fonts: BTreeMap<String, FontUsage> = BTreeMap::new();
    collect_fonts(&root, &mut fonts);
    for area in &page_areas {
        let area_node = LayoutNode {
            kind: NodeKind::Subform,
            name: area.name.clone(),
            geometry: Geometry::default(),
            presence: Presence::Visible,
            relevant: None,
            layout: LayoutKind::Position,
            column_widths: Vec::new(),
            font: TextStyle::default(),
            paragraph: Paragraph::default(),
            margins: Insets::default(),
            border: Border::default(),
            caption: None,
            field: None,
            draw: None,
            children: area.children.clone(),
        };
        collect_fonts(&area_node, &mut fonts);
    }

    let mut scripts = Vec::new();
    template.find_all("script", &mut scripts);
    let mut events = Vec::new();
    template.find_all("event", &mut events);

    warnings.sort();
    warnings.dedup();

    Ok(Template {
        root,
        pages,
        page_areas,
        fonts,
        warnings,
        has_xdp_wrapper,
        script_count: scripts.len(),
        event_count: events.len(),
    })
}

fn parse_pages(
    root_element: &Element,
    root: &LayoutNode,
    warnings: &mut Vec<String>,
) -> (Vec<PageArea>, Vec<PageTemplate>) {
    let mut areas = Vec::new();
    for page_set in root_element.children_named("pageSet") {
        for area in page_set.children_named("pageArea") {
            let page_size = area
                .child("medium")
                .map(parse_medium)
                .unwrap_or(PageSize::LETTER);
            let content_area = area
                .child("contentArea")
                .map(|content| ContentArea {
                    x: length(content.attribute("x")).unwrap_or(0.0),
                    y: length(content.attribute("y")).unwrap_or(0.0),
                    width: length(content.attribute("w")).unwrap_or(page_size.width),
                    height: length(content.attribute("h")).unwrap_or(page_size.height),
                })
                .unwrap_or(ContentArea {
                    x: 0.0,
                    y: 0.0,
                    width: page_size.width,
                    height: page_size.height,
                });
            let defaults = Defaults::default();
            let children = area
                .elements()
                .filter(|element| is_structural(element))
                .filter_map(|element| {
                    let node = build_node(element, &defaults, warnings);
                    (node.kind != NodeKind::Subform || !node.children.is_empty()).then_some(node)
                })
                .collect();
            areas.push(PageArea {
                name: area.attribute("name").unwrap_or("pageArea").to_string(),
                page_size,
                content_area,
                children,
            });
        }
    }
    if areas.is_empty() {
        warnings.push(
            "the template has no pageSet/pageArea; page one uses the letter default".to_string(),
        );
        areas.push(PageArea {
            name: "default".to_string(),
            page_size: PageSize::LETTER,
            content_area: ContentArea {
                x: 0.0,
                y: 0.0,
                width: PageSize::LETTER.width,
                height: PageSize::LETTER.height,
            },
            children: Vec::new(),
        });
    }

    let mut pages = Vec::new();
    for child in root_element.children_named("subform") {
        if Presence::parse(child.attribute("presence")) == Presence::Hidden {
            continue;
        }
        if child
            .attribute("name")
            .is_some_and(|name| name.eq_ignore_ascii_case("barcodes"))
        {
            continue;
        }
        let node = root
            .children
            .iter()
            .find(|candidate| {
                candidate.kind == NodeKind::Subform
                    && candidate.name == child.attribute("name").unwrap_or("")
            })
            .cloned()
            .unwrap_or_else(|| build_node(child, &Defaults::default(), warnings));
        pages.push(PageTemplate {
            name: node.name.clone(),
            break_before: parse_break(child.child("breakBefore"), true),
            break_after: parse_break(child.child("breakAfter"), false),
            node,
        });
    }
    if pages.is_empty() {
        warnings.push(
            "no printable top-level page subform was found; the form root is used as page one"
                .to_string(),
        );
        pages.push(PageTemplate {
            name: root.name.clone(),
            break_before: None,
            break_after: None,
            node: root.clone(),
        });
    }
    (areas, pages)
}

fn parse_break(element: Option<&Element>, before: bool) -> Option<PageBreak> {
    let element = element?;
    Some(PageBreak {
        target_type: element.attribute("targetType").map(str::to_string),
        target: element.attribute("target").map(str::to_string),
        start_new: element
            .attribute("startNew")
            .is_some_and(|value| value == "1" || value.eq_ignore_ascii_case("true")),
        before,
    })
}

fn parse_medium(element: &Element) -> PageSize {
    let short = length(element.attribute("short"));
    let long = length(element.attribute("long"));
    match (short, long) {
        (Some(short), Some(long)) if short > 0.0 && long > 0.0 => PageSize {
            width: short,
            height: long,
        },
        _ => match element.attribute("stock").unwrap_or("letter") {
            "legal" => PageSize {
                width: 612.0,
                height: 1008.0,
            },
            _ => PageSize::LETTER,
        },
    }
}

fn is_structural(element: &Element) -> bool {
    matches!(
        element.name.to_ascii_lowercase().as_str(),
        "subform" | "field" | "draw" | "exclgroup"
    )
}

#[derive(Clone, Default)]
struct Defaults {
    font: TextStyle,
    paragraph: Paragraph,
    margins: Insets,
}

fn build_node(element: &Element, inherited: &Defaults, warnings: &mut Vec<String>) -> LayoutNode {
    let name = element.name.to_ascii_lowercase();
    let kind = match name.as_str() {
        "subform" => NodeKind::Subform,
        "field" => NodeKind::Field,
        "draw" => NodeKind::Draw,
        "exclgroup" => NodeKind::ExclGroup,
        _ => NodeKind::Subform,
    };

    let mut font = inherited.font.clone();
    if let Some(element_font) = element.child("font") {
        apply_font(&mut font, element_font);
    }
    let mut paragraph = inherited.paragraph.clone();
    if let Some(element_paragraph) = element.child("para") {
        apply_paragraph(&mut paragraph, element_paragraph);
    }
    let mut margins = inherited.margins;
    if let Some(element_margin) = element.child("margin") {
        margins = parse_margins(element_margin, margins);
    }
    let border = element
        .child("border")
        .map(parse_border)
        .unwrap_or_default();

    let layout = LayoutKind::parse(element.attribute("layout"));
    if let LayoutKind::Unsupported(value) = &layout {
        warnings.push(format!(
            "layout `{value}` is not implemented; the node is positioned"
        ));
    }
    let column_widths = element
        .attribute("columnWidths")
        .map(|value| {
            value
                .split_whitespace()
                .filter_map(|part| length(Some(part)))
                .collect()
        })
        .unwrap_or_default();

    let caption = element.child("caption").map(|caption| {
        let mut caption_font = font.clone();
        if let Some(caption_font_element) = caption.child("font") {
            apply_font(&mut caption_font, caption_font_element);
        }
        let reserve = length(caption.attribute("reserve")).unwrap_or(0.0);
        let placement = match caption.attribute("placement").unwrap_or("") {
            "top" => Some(CaptionPlacement::Top),
            "bottom" => Some(CaptionPlacement::Bottom),
            "left" => Some(CaptionPlacement::Left),
            "right" => Some(CaptionPlacement::Right),
            _ => None,
        };
        let (text, rich) = caption.child("value").map(value_text).unwrap_or_default();
        Caption {
            text,
            rich,
            placement,
            reserve,
            style: caption_font,
        }
    });

    let field = (kind == NodeKind::Field).then(|| parse_field(element));
    let draw = (kind == NodeKind::Draw).then(|| parse_draw(element));

    let child_defaults = Defaults {
        font: font.clone(),
        paragraph: paragraph.clone(),
        margins,
    };
    let children = element
        .elements()
        .filter(|child| is_structural(child))
        .map(|child| build_node(child, &child_defaults, warnings))
        .collect();

    LayoutNode {
        kind,
        name: element
            .attribute("name")
            .unwrap_or(element.name.as_str())
            .to_string(),
        geometry: Geometry::from_attributes(&element.attributes),
        presence: Presence::parse(element.attribute("presence")),
        relevant: element.attribute("relevant").map(str::to_string),
        layout,
        column_widths,
        font,
        paragraph,
        margins,
        border,
        caption,
        field,
        draw,
        children,
    }
}

fn apply_font(font: &mut TextStyle, element: &Element) {
    if let Some(typeface) = element.attribute("typeface") {
        font.typeface = Some(typeface.to_string());
    }
    if let Some(size) = length(element.attribute("size"))
        && size > 0.0
    {
        font.size = size;
    }
    if let Some(weight) = element.attribute("weight") {
        font.bold = weight.eq_ignore_ascii_case("bold");
    }
    if let Some(style) = element.attribute("style") {
        if style.eq_ignore_ascii_case("italic") || style.eq_ignore_ascii_case("oblique") {
            font.italic = true;
        } else if style.eq_ignore_ascii_case("normal") {
            font.italic = false;
        }
    }
    if let Some(colour) = element
        .child("color")
        .and_then(|color| Color::parse(color.attribute("value").unwrap_or("")))
    {
        font.color = colour;
    }
}

fn apply_paragraph(paragraph: &mut Paragraph, element: &Element) {
    if let Some(value) = element.attribute("hAlign") {
        paragraph.horizontal = match value {
            "center" => HorizontalAlign::Center,
            "right" => HorizontalAlign::Right,
            _ => HorizontalAlign::Left,
        };
    }
    if let Some(value) = element.attribute("vAlign") {
        paragraph.vertical = match value {
            "middle" => VerticalAlign::Middle,
            "bottom" => VerticalAlign::Bottom,
            _ => VerticalAlign::Top,
        };
    }
    if let Some(value) = length(element.attribute("spaceAbove")) {
        paragraph.space_above = value;
    }
    if let Some(value) = length(element.attribute("spaceBelow")) {
        paragraph.space_below = value;
    }
    if let Some(value) = length(element.attribute("textIndent")) {
        paragraph.text_indent = value;
    }
    if let Some(value) = length(element.attribute("marginLeft")) {
        paragraph.margin_left = value;
    }
    if let Some(value) = length(element.attribute("marginRight")) {
        paragraph.margin_right = value;
    }
}

fn parse_margins(element: &Element, defaults: Insets) -> Insets {
    Insets {
        top: length(element.attribute("topInset")).unwrap_or(defaults.top),
        bottom: length(element.attribute("bottomInset")).unwrap_or(defaults.bottom),
        left: length(element.attribute("leftInset")).unwrap_or(defaults.left),
        right: length(element.attribute("rightInset")).unwrap_or(defaults.right),
    }
}

fn parse_border(element: &Element) -> Border {
    let presence = Presence::parse(element.attribute("presence"));
    let mut visible = false;
    let mut thickness = 0.5;
    let mut color = Color::BLACK;
    let mut fill = None;
    for child in element.elements() {
        match child.name.to_ascii_lowercase().as_str() {
            "edge" => {
                if Presence::parse(child.attribute("presence")) == Presence::Visible {
                    visible = true;
                }
                if let Some(value) = length(child.attribute("thickness")) {
                    thickness = value;
                }
                if let Some(value) = child
                    .child("color")
                    .and_then(|color| Color::parse(color.attribute("value").unwrap_or("")))
                {
                    color = value;
                }
            }
            "corner" => {
                if Presence::parse(child.attribute("presence")) == Presence::Visible {
                    visible = true;
                }
            }
            "fill" => {
                fill = child
                    .child("color")
                    .and_then(|color| Color::parse(color.attribute("value").unwrap_or("")));
            }
            _ => {}
        }
    }
    if presence != Presence::Visible {
        visible = false;
    }
    Border {
        visible,
        thickness,
        color,
        fill,
    }
}

fn parse_field(element: &Element) -> FieldInfo {
    let mut field = FieldInfo::default();
    let access = element.attribute("access").unwrap_or("");
    field.read_only =
        access.eq_ignore_ascii_case("readOnly") || access.eq_ignore_ascii_case("protected");
    if let Some(ui) = element.child("ui")
        && let Some(control) = ui.elements().next()
    {
        field.kind = match control.name.to_ascii_lowercase().as_str() {
            "textedit" => FieldType::Text,
            "checkbutton" => FieldType::CheckButton,
            "choicelist" => FieldType::Choice,
            "datetimeedit" => FieldType::DateTime,
            "numericedit" => FieldType::Numeric,
            "button" => FieldType::Button,
            "barcode" => FieldType::Barcode,
            "signature" => FieldType::Signature,
            "picture" => FieldType::Picture,
            _ => FieldType::Unknown,
        };
        if let Some(text_edit) = ui.child("textEdit") {
            field.multiline = text_edit
                .attribute("multiLine")
                .is_some_and(|value| value == "1" || value.eq_ignore_ascii_case("true"));
        }
    }

    if let Some(value) = element.children_named("value").last() {
        let (text, rich) = value_text(value);
        if !text.trim().is_empty() || !rich.is_empty() {
            field.checked = is_checked(&text);
            field.default_value = Some(text);
            field.default_rich = rich;
        }
    }

    let mut items: Vec<Vec<String>> = Vec::new();
    for element_items in element.children_named("items") {
        let values: Vec<String> = element_items
            .children_named("text")
            .map(|text| normalise_space(&text.text()).trim().to_string())
            .collect();
        if !values.is_empty() {
            items.push(values);
        }
    }
    match items.len() {
        0 => {}
        1 => {
            field.items = items[0].clone();
            field.item_values = items[0].clone();
        }
        _ => {
            field.items = items[0].clone();
            field.item_values = items[1].clone();
        }
    }
    field.bind_items = element
        .child("bindItems")
        .and_then(|bind| bind.attribute("ref"))
        .map(str::to_string);
    field
}

fn parse_draw(element: &Element) -> DrawInfo {
    let Some(value) = element.child("value") else {
        return DrawInfo::default();
    };
    if let Some(image) = value.find("image") {
        let content_type = image.attribute("contentType").unwrap_or("").to_string();
        let bytes = image.text().split_whitespace().collect::<String>();
        if let Some(bytes) = decode_base64(&bytes) {
            return DrawInfo {
                kind: DrawKind::Image {
                    content_type,
                    bytes,
                },
                text: String::new(),
                rich: Vec::new(),
            };
        }
        return DrawInfo {
            kind: DrawKind::Unsupported(format!("image `{content_type}` without inline data")),
            text: String::new(),
            rich: Vec::new(),
        };
    }
    if let Some(line) = value.child("line") {
        let thickness = line
            .child("edge")
            .and_then(|edge| length(edge.attribute("thickness")))
            .unwrap_or(0.353);
        return DrawInfo {
            kind: DrawKind::Line { thickness },
            text: String::new(),
            rich: Vec::new(),
        };
    }
    if value.child("rectangle").is_some() {
        return DrawInfo {
            kind: DrawKind::Rectangle { filled: false },
            text: String::new(),
            rich: Vec::new(),
        };
    }
    let (text, rich) = value_text(value);
    DrawInfo {
        kind: DrawKind::Text,
        text,
        rich,
    }
}

/// Returns the value's plain text and rich paragraphs (when the value is XHTML).
fn value_text(value: &Element) -> (String, Vec<RichParagraph>) {
    if let Some(exdata) = value.child("exData") {
        let rich = parse_rich(exdata);
        let text = rich
            .iter()
            .map(RichParagraph::text)
            .collect::<Vec<_>>()
            .join("\n");
        return (normalise_space(&text), rich);
    }
    let text = value
        .children_named("text")
        .map(|text| text.text())
        .collect::<Vec<_>>()
        .join("");
    (normalise_space(&text), Vec::new())
}

fn parse_rich(exdata: &Element) -> Vec<RichParagraph> {
    let mut paragraphs = Vec::new();
    let body = exdata.child("body").unwrap_or(exdata);
    let paragraph_elements: Vec<&Element> = body.children_named("p").collect();
    if paragraph_elements.is_empty() {
        let runs = rich_runs(body, &RichStyle::default());
        if !runs.is_empty() {
            paragraphs.push(RichParagraph {
                runs,
                horizontal: None,
            });
        }
        return paragraphs;
    }
    for paragraph in paragraph_elements {
        let style = rich_style(paragraph.attribute("style"), &RichStyle::default());
        let runs = rich_runs(paragraph, &style);
        if runs.is_empty() {
            continue;
        }
        paragraphs.push(RichParagraph {
            runs,
            horizontal: style.horizontal,
        });
    }
    paragraphs
}

#[derive(Clone, Default)]
struct RichStyle {
    bold: bool,
    italic: bool,
    size: Option<f64>,
    color: Option<Color>,
    horizontal: Option<HorizontalAlign>,
}

fn rich_style(value: Option<&str>, inherited: &RichStyle) -> RichStyle {
    let mut style = inherited.clone();
    let Some(value) = value else {
        return style;
    };
    for declaration in value.split(';') {
        let Some((key, value)) = declaration.split_once(':') else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        let value = value.trim();
        match key.as_str() {
            "font-weight" => style.bold = value.eq_ignore_ascii_case("bold"),
            "font-style" => style.italic = value.eq_ignore_ascii_case("italic"),
            "font-size" => {
                if let Some(size) = length(Some(value)) {
                    style.size = Some(size);
                }
            }
            "color" => style.color = Color::parse(value),
            "text-align" => {
                style.horizontal = match value {
                    "center" => Some(HorizontalAlign::Center),
                    "right" => Some(HorizontalAlign::Right),
                    "left" => Some(HorizontalAlign::Left),
                    _ => style.horizontal,
                }
            }
            _ => {}
        }
    }
    style
}

fn rich_runs(element: &Element, inherited: &RichStyle) -> Vec<RichRun> {
    let mut runs = Vec::new();
    for child in &element.children {
        match child {
            crate::xml::Node::Text(text) => {
                let text = normalise_space(text);
                if text.is_empty() {
                    continue;
                }
                runs.push(RichRun {
                    text,
                    bold: inherited.bold,
                    italic: inherited.italic,
                    size: inherited.size,
                    color: inherited.color,
                });
            }
            crate::xml::Node::Element(child_element) => {
                if child_element.name.eq_ignore_ascii_case("br") {
                    runs.push(RichRun {
                        text: "\n".to_string(),
                        bold: false,
                        italic: false,
                        size: None,
                        color: None,
                    });
                    continue;
                }
                if child_element.name.eq_ignore_ascii_case("p") {
                    continue;
                }
                let style = rich_style(child_element.attribute("style"), inherited);
                runs.extend(rich_runs(child_element, &style));
            }
        }
    }
    runs
}

fn collect_fonts(node: &LayoutNode, fonts: &mut BTreeMap<String, FontUsage>) {
    let typeface = node
        .font
        .typeface
        .clone()
        .unwrap_or_else(|| "(default)".to_string());
    fonts
        .entry(typeface)
        .or_insert_with(|| FontUsage {
            typeface: node
                .font
                .typeface
                .clone()
                .unwrap_or_else(|| "(default)".to_string()),
            ..FontUsage::default()
        })
        .add(node.font.size);
    if let Some(caption) = &node.caption {
        let typeface = caption
            .style
            .typeface
            .clone()
            .unwrap_or_else(|| "(default)".to_string());
        fonts
            .entry(typeface)
            .or_insert_with(|| FontUsage {
                typeface: "(default)".to_string(),
                ..FontUsage::default()
            })
            .add(caption.style.size);
    }
    if let Some(draw) = &node.draw {
        for paragraph in &draw.rich {
            for run in &paragraph.runs {
                if let Some(size) = run.size {
                    fonts
                        .entry("(rich text)".to_string())
                        .or_insert_with(|| FontUsage {
                            typeface: "(rich text)".to_string(),
                            ..FontUsage::default()
                        })
                        .add(size);
                }
            }
        }
    }
    for child in &node.children {
        collect_fonts(child, fonts);
    }
}

fn is_checked(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "1" | "on" | "true" | "yes" | "y"
    )
}

/// A small base64 decoder for inline XFA images (`<image>base64…</image>`).
pub fn decode_base64(input: &str) -> Option<Vec<u8>> {
    if input.is_empty() {
        return None;
    }
    let mut output = Vec::with_capacity(input.len() * 3 / 4);
    let mut buffer: u32 = 0;
    let mut bits = 0;
    for byte in input.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            _ => continue,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            output.push(((buffer >> bits) & 0xFF) as u8);
        }
    }
    (!output.is_empty()).then_some(output)
}

/// The set of layout constructs this reader knows, for the report's "skipped" list.
pub fn unsupported_constructs(template: &Template) -> BTreeSet<String> {
    let mut set = BTreeSet::new();
    fn walk(node: &LayoutNode, set: &mut BTreeSet<String>) {
        if let LayoutKind::Unsupported(value) = &node.layout {
            set.insert(format!("layout:{value}"));
        }
        if let Some(draw) = &node.draw
            && let DrawKind::Unsupported(reason) = &draw.kind
        {
            set.insert(format!("draw:{reason}"));
        }
        for child in &node.children {
            walk(child, set);
        }
    }
    walk(&template.root, &mut set);
    for area in &template.page_areas {
        for child in &area.children {
            walk(child, &mut set);
        }
    }
    set
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEMPLATE: &str = r#"
        <template xmlns="http://www.xfa.org/schema/xfa-template/2.8/">
          <subform name="form1" layout="tb">
            <pageSet>
              <pageArea name="Page1">
                <contentArea x="7.62mm" y="16.75mm" w="200.66mm" h="247.41mm"/>
                <medium stock="letter" short="215.9mm" long="279.4mm"/>
                <draw name="title" x="7.62mm" y="10mm" w="100mm" h="5mm">
                  <value><text>Form title</text></value>
                </draw>
              </pageArea>
            </pageSet>
            <subform name="Page1" w="200.66mm" layout="tb">
              <breakBefore targetType="pageArea" target="Page1"/>
              <draw name="heading" w="200mm" h="4mm">
                <value><text>Heading</text></value>
              </draw>
              <field name="Name" x="0mm" y="5mm" w="100mm" h="12mm">
                <ui><textEdit multiLine="1"/></ui>
                <caption placement="top" reserve="3mm"><value><text>Name</text></value></caption>
                <font typeface="Myriad Pro" size="8pt"/>
                <value><text>Ada</text></value>
              </field>
              <field name="Agree" w="40mm" h="5mm" x="120mm" y="5mm">
                <ui><checkButton><border><fill><color value="255,255,255"/></fill></border></checkButton></ui>
                <items><text>1</text><text>0</text></items>
                <value><text>1</text></value>
              </field>
            </subform>
          </subform>
        </template>
    "#;

    #[test]
    fn reads_pages_fields_fonts_and_captions() {
        let template = parse_template(TEMPLATE.as_bytes()).expect("template");
        assert_eq!(template.pages.len(), 1);
        assert_eq!(template.page_areas.len(), 1);
        assert!((template.page_areas[0].page_size.width - 612.0).abs() < 0.1);
        let fields = template.fields();
        assert_eq!(fields.len(), 2);
        assert_eq!(fields[0].path, "Page1.Name[0]");
        assert_eq!(fields[0].kind, FieldType::Text);
        assert_eq!(fields[0].value.as_deref(), Some("Ada"));
        assert_eq!(fields[1].kind, FieldType::CheckButton);
        assert!(template.fonts.contains_key("Myriad Pro"));
        let page = &template.pages[0];
        assert!(
            page.break_before
                .as_ref()
                .is_some_and(|value| value.target.as_deref() == Some("Page1"))
        );
    }

    #[test]
    fn rich_text_keeps_paragraphs_and_bold_runs() {
        let template = parse_template(
            br#"<template><subform name="f"><subform name="Page1"><draw name="d"><value>
              <exData contentType="text/html"><body><p style="font-weight:normal">a)<span style="font-weight:bold"> bold</span></p><p>second</p></body></exData>
            </value></draw></subform></subform></template>"#,
        )
        .expect("template");
        let draw = template
            .draws()
            .into_iter()
            .find(|draw| draw.path.ends_with("d[0]"))
            .expect("draw");
        assert_eq!(draw.text.as_deref(), Some("a) bold\nsecond"));
    }

    #[test]
    fn base64_decodes_inline_images() {
        assert_eq!(
            decode_base64("SGVsbG8=").as_deref(),
            Some(b"Hello".as_slice())
        );
        assert_eq!(decode_base64("!!!"), None);
    }
}
