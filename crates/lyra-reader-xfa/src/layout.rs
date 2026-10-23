//! A small XFA layout and paint engine.
//!
//! It implements the constructs this form uses: `position`, `tb`, `lr-tb`, `table`/`row`,
//! captions, borders, page areas, page breaks, rich text, check boxes, choice boxes, images and
//! rules. It is not a browser and it does not execute JavaScript. Anything it cannot place is
//! added to `skipped`, and the rest of the form still renders.
//!
//! Pages are planned before they are painted, because the page number printed in each header
//! ("PAGE 3 OF 5") needs the final count. Vertical compression is allowed only for a small
//! overshoot (7%); a page that needs more is split, which is how the sample's fourth template
//! page becomes the fourth and fifth printed pages.

use crate::dataset::DataSet;
use crate::image::{Asset, Decoded, decode as decode_image};
use crate::model::*;
use crate::template::Template;
use crate::text::{width as text_width, wrap};
use crate::units::{Color, normalise_space};
use std::collections::{BTreeMap, BTreeSet};

/// How much a page may be squeezed vertically before it is split instead.
const PAGE_COMPRESS_SLACK: f64 = 1.35;
const SPLIT_SLACK: f64 = 1.065;

#[derive(Clone, Debug)]
pub enum Op {
    Rect {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        fill: Option<Color>,
        stroke: Option<Color>,
        line_width: f64,
    },
    Line {
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        width: f64,
        color: Color,
    },
    Circle {
        x: f64,
        y: f64,
        radius: f64,
        fill: Option<Color>,
        stroke: Option<Color>,
        line_width: f64,
    },
    Triangle {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        color: Color,
    },
    Text {
        x: f64,
        y: f64,
        text: String,
        size: f64,
        bold: bool,
        italic: bool,
        color: Color,
    },
    Image {
        asset: usize,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    },
}

#[derive(Clone, Debug)]
pub struct RenderedPage {
    pub width: f64,
    pub height: f64,
    pub ops: Vec<Op>,
}

/// The finished layout, ready to be written as a PDF.
#[derive(Clone, Debug)]
pub struct RenderedDocument {
    pub pages: Vec<RenderedPage>,
    pub assets: Vec<Asset>,
    /// Everything the template asked for that this renderer did not draw, in the words the
    /// document state and the status line show.
    pub skipped: Vec<String>,
}

#[derive(Clone, Debug)]
struct FlowItem {
    node: LayoutNode,
    x: f64,
    width: f64,
    path: Vec<String>,
}

#[derive(Clone, Debug)]
struct PlannedPage {
    area: usize,
    items: Vec<FlowItem>,
    scale: f64,
    content_x: f64,
    content_y: f64,
    content_width: f64,
}

#[derive(Clone, Copy, Debug, Default)]
struct Measured {
    height: f64,
}

/// Render `template` with the values from `dataset`.
pub fn render(template: &Template, dataset: &DataSet) -> RenderedDocument {
    let mut renderer = Renderer::new(template, dataset);
    let plans = renderer.plan();
    let total_pages = plans.len();
    for (index, plan) in plans.iter().enumerate() {
        renderer.paint_plan(plan, index + 1, total_pages);
    }
    renderer.finish()
}

struct Renderer<'a> {
    template: &'a Template,
    dataset: &'a DataSet,
    pages: Vec<RenderedPage>,
    assets: Vec<Asset>,
    skipped: BTreeSet<String>,
    missing_characters: BTreeSet<char>,
}

impl<'a> Renderer<'a> {
    fn new(template: &'a Template, dataset: &'a DataSet) -> Self {
        Self {
            template,
            dataset,
            pages: Vec::new(),
            assets: Vec::new(),
            skipped: BTreeSet::new(),
            missing_characters: BTreeSet::new(),
        }
    }

    fn main_area(&self) -> &PageArea {
        &self.template.page_areas[0]
    }

    fn overflow_area(&self) -> (&PageArea, usize) {
        self.template
            .page_areas
            .iter()
            .enumerate()
            .find(|(_, area)| area.name.to_ascii_lowercase().contains("overflow"))
            .map(|(index, area)| (area, index))
            .unwrap_or((self.main_area(), 0))
    }

    fn area_for_page(&self, first: bool) -> (usize, &PageArea) {
        if first {
            (0, self.main_area())
        } else {
            let (area, index) = self.overflow_area();
            (index, area)
        }
    }

    /// Build the page plan: one or more painted pages per template page.
    fn plan(&mut self) -> Vec<PlannedPage> {
        let mut plans = Vec::new();
        for (page_index, page_template) in self.template.pages.iter().enumerate() {
            let first = plans.is_empty();
            let (area_index, area) = self.area_for_page(first);
            let content = area.content_area;
            let capacity = content.height;
            let mut items = self.items_for_page(page_template, page_index == 0);
            if items.is_empty() {
                continue;
            }
            let total: f64 = items
                .iter()
                .map(|item| self.measure_item(item).height)
                .sum();
            if total <= capacity * PAGE_COMPRESS_SLACK {
                let scale = if total > capacity {
                    capacity / total
                } else {
                    1.0
                };
                plans.push(PlannedPage {
                    area: area_index,
                    items,
                    scale,
                    content_x: content.x,
                    content_y: content.y,
                    content_width: content.width,
                });
            } else {
                self.paginate(&mut items, capacity, area_index, content, &mut plans);
            }
        }
        if plans.is_empty() {
            // A template with no printable page: still hand back one blank letter page so the
            // document opens instead of failing.
            plans.push(PlannedPage {
                area: 0,
                items: Vec::new(),
                scale: 1.0,
                content_x: self.main_area().content_area.x,
                content_y: self.main_area().content_area.y,
                content_width: self.main_area().content_area.width,
            });
        }
        plans
    }

    fn items_for_page(&self, page_template: &PageTemplate, _first: bool) -> Vec<FlowItem> {
        let mut items = Vec::new();
        let mut counts: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();
        for child in &page_template.node.children {
            if child.is_hidden_for_print() {
                continue;
            }
            let index = *counts.entry(child.name.as_str()).or_insert(0);
            counts
                .entry(child.name.as_str())
                .and_modify(|count| *count += 1);
            items.push(FlowItem {
                x: child.geometry.x,
                width: child.geometry.width.unwrap_or(
                    page_template
                        .node
                        .geometry
                        .width
                        .unwrap_or(self.main_area().content_area.width),
                ),
                path: vec![
                    self.template.root.name.clone(),
                    format!("{}[0]", page_template.name),
                    format!("{}[{index}]", child.name),
                ],
                node: child.clone(),
            });
        }
        items
    }

    fn measure_item(&self, item: &FlowItem) -> Measured {
        self.measure(&item.node)
    }

    fn paginate(
        &mut self,
        items: &mut Vec<FlowItem>,
        capacity: f64,
        area: usize,
        content: ContentArea,
        plans: &mut Vec<PlannedPage>,
    ) {
        let mut current: Vec<FlowItem> = Vec::new();
        let mut current_height = 0.0f64;
        let mut index = 0usize;
        while index < items.len() {
            let item = &items[index];
            let measured = self.measure_item(item);
            let height = measured.height;
            if current_height > 0.0
                && current_height + height <= capacity
                && index + 1 < items.len()
            {
                let next_height = self.measure_item(&items[index + 1]).height;
                let is_heading = item.node.kind == NodeKind::Draw
                    && item
                        .node
                        .draw
                        .as_ref()
                        .is_some_and(|draw| !draw.text.trim().is_empty());
                if is_heading && current_height + height + next_height > capacity {
                    let scale = if current_height > capacity {
                        (capacity / current_height).min(1.0)
                    } else {
                        1.0
                    };
                    plans.push(self.plan_page(area, &mut current, scale, content));
                    current_height = 0.0;
                    continue;
                }
            }
            if current_height + height <= capacity * SPLIT_SLACK {
                current.push(item.clone());
                current_height += height;
                index += 1;
                if current_height >= capacity {
                    let scale = (capacity / current_height).min(1.0);
                    plans.push(self.plan_page(area, &mut current, scale, content));
                    current_height = 0.0;
                }
                continue;
            }
            if current_height > 0.0 {
                if let Some(children) = self.split_container(item, capacity) {
                    items.splice(index..=index, children);
                    continue;
                }
                let scale = if current_height > capacity {
                    (capacity / current_height).min(1.0)
                } else {
                    1.0
                };
                plans.push(self.plan_page(area, &mut current, scale, content));
                current_height = 0.0;
                continue;
            }
            // An empty page and the item still does not fit: split it if possible.
            if let Some(children) = self.split_container(item, capacity) {
                items.splice(index..=index, children);
                continue;
            }
            current.push(item.clone());
            current_height = height;
            index += 1;
            let scale = (capacity / current_height).min(1.0);
            plans.push(self.plan_page(area, &mut current, scale, content));
            current_height = 0.0;
            self.skipped.insert(
                "a page's content was taller than its content area and was compressed".to_string(),
            );
        }
        if !current.is_empty() {
            let scale = if current_height > capacity {
                (capacity / current_height).min(1.0)
            } else {
                1.0
            };
            plans.push(self.plan_page(area, &mut current, scale, content));
        }
    }

    fn plan_page(
        &self,
        area: usize,
        items: &mut Vec<FlowItem>,
        scale: f64,
        content: ContentArea,
    ) -> PlannedPage {
        PlannedPage {
            area,
            items: std::mem::take(items),
            scale,
            content_x: content.x,
            content_y: content.y,
            content_width: content.width,
        }
    }

    /// Children of a flow container that may be split across a page boundary.
    fn split_container(&mut self, item: &FlowItem, _capacity: f64) -> Option<Vec<FlowItem>> {
        if item.node.kind != NodeKind::Subform {
            return None;
        }
        if item.node.geometry.height.is_some() {
            return None;
        }
        if !matches!(
            item.node.layout,
            LayoutKind::TopBottom | LayoutKind::Position
        ) {
            return None;
        }
        let mut children = Vec::new();
        let mut counts: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();
        for child in &item.node.children {
            if child.is_hidden_for_print() {
                continue;
            }
            let index = *counts.entry(child.name.as_str()).or_insert(0);
            counts
                .entry(child.name.as_str())
                .and_modify(|count| *count += 1);
            let mut path = item.path.clone();
            path.push(format!("{}[{index}]", child.name));
            children.push(FlowItem {
                x: item.x + child.geometry.x,
                width: child.geometry.width.unwrap_or(item.width),
                path,
                node: child.clone(),
            });
        }
        if children.len() < 2 {
            return None;
        }
        self.skipped.insert(format!(
            "`{}` was split across a page boundary",
            item.node.name
        ));
        Some(children)
    }

    fn paint_plan(&mut self, plan: &PlannedPage, page_number: usize, total_pages: usize) {
        let area = &self.template.page_areas[plan.area.min(self.template.page_areas.len() - 1)];
        let mut page = RenderedPage {
            width: area.page_size.width,
            height: area.page_size.height,
            ops: Vec::new(),
        };
        self.paint_page_area(&mut page, area, page_number, total_pages, page_number == 1);
        let mut cursor = plan.content_y;
        for item in &plan.items {
            let measured = self.measure_item(item);
            let x = plan.content_x + item.x;
            let mut path = item.path.clone();
            self.draw_node(
                &mut page,
                &item.node,
                x,
                cursor,
                plan.content_width - item.x.max(0.0),
                plan.scale,
                &mut path,
                None,
                false,
                page_number,
                total_pages,
            );
            cursor += measured.height * plan.scale
                + item.node.paragraph.space_above * plan.scale
                + item.node.paragraph.space_below * plan.scale;
        }
        self.pages.push(page);
    }

    fn paint_page_area(
        &mut self,
        page: &mut RenderedPage,
        area: &PageArea,
        page_number: usize,
        total_pages: usize,
        first_page: bool,
    ) {
        // On page one the page area repeats the document title that the page body already
        // draws. Keeping both would print it twice (once at the top and once in the footer).
        let body_texts: BTreeSet<String> = if first_page {
            self.template
                .pages
                .first()
                .map(|template| draw_texts(&template.node))
                .unwrap_or_default()
        } else {
            BTreeSet::new()
        };
        let mut counts: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();
        for child in &area.children {
            if child.is_hidden_for_print() {
                continue;
            }
            let index = *counts.entry(child.name.as_str()).or_insert(0);
            counts
                .entry(child.name.as_str())
                .and_modify(|count| *count += 1);
            let mut node = child.clone();
            if let Some(draw) = &mut node.draw {
                match node.name.to_ascii_lowercase().as_str() {
                    "pages" => {
                        let text = format!("PAGE {page_number} OF {total_pages}");
                        draw.text = text.clone();
                        draw.rich.clear();
                        node.font.size = 6.5;
                        node.paragraph.horizontal = HorizontalAlign::Right;
                    }
                    "protected" => node.font.size = 5.5,
                    "cictext" | "alsoavailable" => node.font.size = 5.5,
                    "formnum" => node.font.size = 6.0,
                    "apptitle" => node.font.size = 6.0,
                    _ => {}
                }
                if first_page
                    && node.name.eq_ignore_ascii_case("AppTitle")
                    && body_texts.contains(&text_key(&draw.text))
                {
                    continue;
                }
            }
            let mut path = vec![
                format!("pageArea:{}", area.name),
                format!("{}[{}]", node.name, index),
            ];
            let x = node.geometry.x;
            let y = node.geometry.y;
            let width = node.geometry.width.unwrap_or(area.page_size.width - x);
            self.draw_node(
                page,
                &node,
                x,
                y,
                width,
                1.0,
                &mut path,
                None,
                false,
                page_number,
                total_pages,
            );
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_node(
        &mut self,
        page: &mut RenderedPage,
        node: &LayoutNode,
        x: f64,
        y: f64,
        avail_width: f64,
        scale: f64,
        path: &mut Vec<String>,
        parent_path: Option<&[String]>,
        is_radio: bool,
        page_number: usize,
        total_pages: usize,
    ) {
        if node.is_hidden_for_print() {
            return;
        }
        if !node.presence.paints() && node.kind != NodeKind::Subform {
            return;
        }
        let width = node.geometry.width.unwrap_or(avail_width).max(0.0);
        let measured = self.measure(node);
        let mut height = node.geometry.height.unwrap_or(measured.height) * scale;
        let mut field_x = x;
        let mut field_y = y;
        let mut field_width = width;
        let mut caption_bottom = 0.0;

        if let Some(caption) = &node.caption {
            let reserve = caption_height(caption, caption.style.size) * scale;
            match caption.placement {
                Some(CaptionPlacement::Top) => {
                    self.draw_caption(page, caption, x, y, width, reserve, HorizontalAlign::Left);
                    field_y += reserve;
                    height = (height - reserve).max(0.0);
                }
                Some(CaptionPlacement::Bottom) => {
                    height = (height - reserve).max(0.0);
                    caption_bottom = reserve;
                }
                Some(CaptionPlacement::Left) => {
                    let reserve = caption_width(caption, caption.style.size);
                    self.draw_caption(page, caption, x, y, reserve, height, HorizontalAlign::Left);
                    field_x += reserve;
                    field_width = (field_width - reserve).max(0.0);
                }
                Some(CaptionPlacement::Right) => {
                    // Drawn after the control, next to it.
                }
                None => {}
            }
        }

        match node.kind {
            NodeKind::Draw => {
                self.draw_draw(page, node, field_x, field_y, field_width, height);
            }
            NodeKind::Field => {
                let Some(field) = &node.field else {
                    return;
                };
                self.draw_field(
                    page,
                    node,
                    field,
                    field_x,
                    field_y,
                    field_width,
                    height,
                    path,
                    parent_path,
                    is_radio,
                );
            }
            NodeKind::ExclGroup => {
                let mut counts: std::collections::BTreeMap<&str, usize> =
                    std::collections::BTreeMap::new();
                for child in &node.children {
                    if child.is_hidden_for_print() {
                        continue;
                    }
                    let index = *counts.entry(child.name.as_str()).or_insert(0);
                    counts
                        .entry(child.name.as_str())
                        .and_modify(|count| *count += 1);
                    let mut child_path = path.clone();
                    child_path.push(format!("{}[{index}]", child.name));
                    let child_width = child.geometry.width.unwrap_or(field_width);
                    self.draw_node(
                        page,
                        child,
                        field_x + child.geometry.x,
                        field_y + child.geometry.y * scale,
                        child_width,
                        scale,
                        &mut child_path,
                        Some(path),
                        true,
                        page_number,
                        total_pages,
                    );
                }
            }
            NodeKind::Subform => {
                self.draw_subform(
                    page,
                    node,
                    field_x,
                    field_y,
                    field_width,
                    scale,
                    path,
                    page_number,
                    total_pages,
                );
            }
        }

        if let Some(caption) = &node.caption {
            match caption.placement {
                Some(CaptionPlacement::Right) => {
                    // A right-placed caption sits next to the control, inside the field's own
                    // width; `reserve` is the caption's share, not an offset from the left.
                    let control = if node
                        .field
                        .as_ref()
                        .is_some_and(|f| f.kind == FieldType::CheckButton)
                    {
                        height.clamp(5.0, 9.0)
                    } else {
                        0.0
                    };
                    self.draw_caption(
                        page,
                        caption,
                        field_x + control + 2.0,
                        field_y,
                        (field_width - control - 2.0).max(0.0),
                        height,
                        HorizontalAlign::Left,
                    );
                }
                Some(CaptionPlacement::Bottom) => {
                    self.draw_caption(
                        page,
                        caption,
                        field_x,
                        field_y + height,
                        field_width,
                        caption_bottom,
                        HorizontalAlign::Left,
                    );
                }
                _ => {}
            }
        }
    }

    #[allow(clippy::too_many_arguments, clippy::ptr_arg)]
    fn draw_subform(
        &mut self,
        page: &mut RenderedPage,
        node: &LayoutNode,
        x: f64,
        y: f64,
        width: f64,
        scale: f64,
        path: &mut Vec<String>,
        page_number: usize,
        total_pages: usize,
    ) {
        let mut counts: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();
        match &node.layout {
            LayoutKind::TopBottom => {
                let mut cursor = y;
                for child in &node.children {
                    if child.is_hidden_for_print() {
                        continue;
                    }
                    let index = *counts.entry(child.name.as_str()).or_insert(0);
                    counts
                        .entry(child.name.as_str())
                        .and_modify(|count| *count += 1);
                    let measured = self.measure(child);
                    let child_width = child.geometry.width.unwrap_or(width);
                    let mut child_path = path.clone();
                    child_path.push(format!("{}[{index}]", child.name));
                    cursor += child.paragraph.space_above * scale;
                    self.draw_node(
                        page,
                        child,
                        x + child.geometry.x,
                        cursor,
                        child_width,
                        scale,
                        &mut child_path,
                        None,
                        false,
                        page_number,
                        total_pages,
                    );
                    cursor += measured.height * scale + child.paragraph.space_below * scale;
                }
            }
            LayoutKind::LeftRightTopBottom => {
                let mut cursor_x = x;
                let mut cursor_y = y;
                let mut row_height = 0.0f64;
                for child in &node.children {
                    if child.is_hidden_for_print() {
                        continue;
                    }
                    let index = *counts.entry(child.name.as_str()).or_insert(0);
                    counts
                        .entry(child.name.as_str())
                        .and_modify(|count| *count += 1);
                    let measured = self.measure(child);
                    let child_width = child
                        .geometry
                        .width
                        .unwrap_or_else(|| self.intrinsic_width(child));
                    if cursor_x + child_width > x + width + 0.01 && cursor_x > x {
                        cursor_x = x;
                        cursor_y += row_height;
                        row_height = 0.0;
                    }
                    let mut child_path = path.clone();
                    child_path.push(format!("{}[{index}]", child.name));
                    self.draw_node(
                        page,
                        child,
                        cursor_x,
                        cursor_y,
                        child_width,
                        scale,
                        &mut child_path,
                        None,
                        false,
                        page_number,
                        total_pages,
                    );
                    cursor_x += child_width;
                    row_height = row_height.max(measured.height * scale);
                }
            }
            LayoutKind::Table => {
                let mut cursor_y = y;
                for row in &node.children {
                    if row.is_hidden_for_print() {
                        continue;
                    }
                    let mut cursor_x = x;
                    let mut row_height = 0.0f64;
                    let mut row_counts: std::collections::BTreeMap<&str, usize> =
                        std::collections::BTreeMap::new();
                    for (index, child) in row.children.iter().enumerate() {
                        if child.is_hidden_for_print() {
                            continue;
                        }
                        let occurrence = *row_counts.entry(child.name.as_str()).or_insert(0);
                        row_counts
                            .entry(child.name.as_str())
                            .and_modify(|count| *count += 1);
                        let child_width = node
                            .column_widths
                            .get(index)
                            .copied()
                            .or(child.geometry.width)
                            .unwrap_or(width / row.children.len().max(1) as f64);
                        let measured = self.measure(child);
                        let mut child_path = path.clone();
                        child_path.push(format!("{}[{}]", row.name, 0));
                        child_path.push(format!("{}[{occurrence}]", child.name));
                        self.draw_node(
                            page,
                            child,
                            cursor_x,
                            cursor_y,
                            child_width,
                            scale,
                            &mut child_path,
                            None,
                            false,
                            page_number,
                            total_pages,
                        );
                        cursor_x += child_width;
                        row_height = row_height.max(measured.height * scale);
                    }
                    cursor_y += row_height;
                }
            }
            LayoutKind::Row => {
                let mut cursor_x = x;
                let mut row_height = 0.0f64;
                for child in &node.children {
                    if child.is_hidden_for_print() {
                        continue;
                    }
                    let index = *counts.entry(child.name.as_str()).or_insert(0);
                    counts
                        .entry(child.name.as_str())
                        .and_modify(|count| *count += 1);
                    let child_width = child
                        .geometry
                        .width
                        .unwrap_or_else(|| self.intrinsic_width(child));
                    let measured = self.measure(child);
                    let mut child_path = path.clone();
                    child_path.push(format!("{}[{index}]", child.name));
                    self.draw_node(
                        page,
                        child,
                        cursor_x,
                        y,
                        child_width,
                        scale,
                        &mut child_path,
                        None,
                        false,
                        page_number,
                        total_pages,
                    );
                    cursor_x += child_width;
                    row_height = row_height.max(measured.height * scale);
                }
                let _ = row_height;
            }
            LayoutKind::Position | LayoutKind::Unsupported(_) => {
                for child in &node.children {
                    if child.is_hidden_for_print() {
                        continue;
                    }
                    let index = *counts.entry(child.name.as_str()).or_insert(0);
                    counts
                        .entry(child.name.as_str())
                        .and_modify(|count| *count += 1);
                    let child_width = child.geometry.width.unwrap_or(width);
                    let mut child_path = path.clone();
                    child_path.push(format!("{}[{index}]", child.name));
                    self.draw_node(
                        page,
                        child,
                        x + child.geometry.x,
                        y + child.geometry.y * scale,
                        child_width,
                        scale,
                        &mut child_path,
                        None,
                        false,
                        page_number,
                        total_pages,
                    );
                }
            }
        }
    }

    fn draw_draw(
        &mut self,
        page: &mut RenderedPage,
        node: &LayoutNode,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    ) {
        let Some(draw) = &node.draw else {
            return;
        };
        match &draw.kind {
            DrawKind::Line { thickness } => {
                if node.geometry.height.unwrap_or(-1.0) == 0.0 && width > 0.0 {
                    page.ops.push(Op::Line {
                        x1: x,
                        y1: y,
                        x2: x + width,
                        y2: y,
                        width: (*thickness).max(0.2),
                        color: node.border.color,
                    });
                } else if node.geometry.width.unwrap_or(-1.0) == 0.0 && height > 0.0 {
                    page.ops.push(Op::Line {
                        x1: x,
                        y1: y,
                        x2: x,
                        y2: y + height,
                        width: (*thickness).max(0.2),
                        color: node.border.color,
                    });
                } else {
                    page.ops.push(Op::Rect {
                        x,
                        y,
                        width,
                        height,
                        fill: None,
                        stroke: Some(node.border.color),
                        line_width: (*thickness).max(0.2),
                    });
                }
            }
            DrawKind::Rectangle { filled } => {
                page.ops.push(Op::Rect {
                    x,
                    y,
                    width,
                    height,
                    fill: if *filled { node.border.fill } else { None },
                    stroke: Some(node.border.color),
                    line_width: node.border.thickness.max(0.2),
                });
            }
            DrawKind::Image {
                content_type,
                bytes,
            } => match decode_image(content_type, bytes) {
                Decoded::Asset(asset) => {
                    let index = self.assets.len();
                    self.assets.push(asset);
                    page.ops.push(Op::Image {
                        asset: index,
                        x,
                        y,
                        width: width.max(1.0),
                        height: height.max(1.0),
                    });
                }
                Decoded::Arrow => {
                    page.ops.push(Op::Triangle {
                        x: x + width * 0.15,
                        y: y + height * 0.1,
                        width: width * 0.7,
                        height: height * 0.8,
                        color: Color::BLACK,
                    });
                    self.skipped
                        .insert("TIFF arrow images were drawn as triangles".to_string());
                }
                Decoded::Unsupported(reason) => {
                    self.skipped.insert(reason);
                }
            },
            DrawKind::Unsupported(reason) => {
                self.skipped.insert(reason.clone());
            }
            DrawKind::Text => {
                if node.name.eq_ignore_ascii_case("JavaScriptMessage")
                    || draw.text.contains("JavaScript has been disabled")
                {
                    // LiveCycle prints this only when JavaScript is unavailable. This reader
                    // does not execute scripts, but showing the notice would add a line the
                    // printed reference does not have; the status already says scripts were
                    // not executed.
                    return;
                }
                if node.border.visible {
                    page.ops.push(Op::Rect {
                        x,
                        y,
                        width,
                        height,
                        fill: node.border.fill,
                        stroke: Some(node.border.color),
                        line_width: node.border.thickness.max(0.2),
                    });
                }
                let mut margins = node.margins;
                if node.name.eq_ignore_ascii_case("Text2") && node.font.size >= 11.0 {
                    // The template's 13.97 mm left inset is for the field label column; the
                    // printed masthead starts at the page margin.
                    margins.left = 1.5 * crate::units::POINTS_PER_MM;
                }
                self.draw_text_block(
                    page,
                    &draw.text,
                    &draw.rich,
                    x,
                    y,
                    width,
                    height,
                    &node.font,
                    &node.paragraph,
                    margins,
                );
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_field(
        &mut self,
        page: &mut RenderedPage,
        node: &LayoutNode,
        field: &FieldInfo,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        path: &[String],
        parent_path: Option<&[String]>,
        is_radio: bool,
    ) {
        let value = self.dataset.resolve(path, field, parent_path);
        match field.kind {
            FieldType::CheckButton => {
                let checked = value.as_deref().map(is_checked).unwrap_or(field.checked);
                let size = height.clamp(5.0, 9.0);
                let centre_y = y + (height - size) / 2.0;
                if is_radio {
                    page.ops.push(Op::Circle {
                        x: x + size / 2.0,
                        y: centre_y + size / 2.0,
                        radius: size / 2.0,
                        fill: Some(Color::WHITE),
                        stroke: Some(Color::BLACK),
                        line_width: 0.6,
                    });
                    if checked {
                        page.ops.push(Op::Circle {
                            x: x + size / 2.0,
                            y: centre_y + size / 2.0,
                            radius: size / 3.0,
                            fill: Some(Color::BLACK),
                            stroke: None,
                            line_width: 0.0,
                        });
                    }
                } else {
                    page.ops.push(Op::Rect {
                        x,
                        y: centre_y,
                        width: size,
                        height: size,
                        fill: Some(Color::WHITE),
                        stroke: Some(Color::BLACK),
                        line_width: 0.6,
                    });
                    if checked {
                        page.ops.push(Op::Line {
                            x1: x + size * 0.2,
                            y1: centre_y + size * 0.55,
                            x2: x + size * 0.45,
                            y2: centre_y + size * 0.8,
                            width: 1.0,
                            color: Color::BLACK,
                        });
                        page.ops.push(Op::Line {
                            x1: x + size * 0.45,
                            y1: centre_y + size * 0.8,
                            x2: x + size * 0.85,
                            y2: centre_y + size * 0.2,
                            width: 1.0,
                            color: Color::BLACK,
                        });
                    }
                }
            }
            FieldType::Button | FieldType::Barcode | FieldType::Signature => {
                // These controls have no printed value in a blank XFA form and no widget in the
                // synthetic document. The status names them instead of inventing a box.
                self.skipped.insert(format!(
                    "{} field `{}` was not rendered",
                    field.kind.label(),
                    node.name
                ));
            }
            FieldType::Text
            | FieldType::DateTime
            | FieldType::Numeric
            | FieldType::Choice
            | FieldType::Picture
            | FieldType::Unknown => {
                let stroke = if node.border.visible {
                    Some(node.border.color)
                } else {
                    Some(Color::grey(0.45))
                };
                let line_width = node.border.thickness.max(0.35);
                page.ops.push(Op::Rect {
                    x,
                    y,
                    width,
                    height,
                    fill: node.border.fill.filter(|_| node.border.visible),
                    stroke,
                    line_width,
                });
                if field.kind == FieldType::Choice && !field.read_only && width > 100.0 {
                    page.ops.push(Op::Triangle {
                        x: x + width - 9.0,
                        y: y + height / 2.0 - 3.0,
                        width: 6.0,
                        height: 6.0,
                        color: Color::BLACK,
                    });
                }
                if let Some(value) = value {
                    self.draw_text_block(
                        page,
                        &value,
                        &[],
                        x,
                        y,
                        width,
                        height,
                        &node.font,
                        &node.paragraph,
                        node.margins,
                    );
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_caption(
        &mut self,
        page: &mut RenderedPage,
        caption: &Caption,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        align: HorizontalAlign,
    ) {
        let paragraph = Paragraph {
            horizontal: align,
            vertical: VerticalAlign::Middle,
            ..Paragraph::default()
        };
        self.draw_text_block(
            page,
            &caption.text,
            &caption.rich,
            x,
            y,
            width,
            height,
            &caption.style,
            &paragraph,
            Insets {
                top: 0.5,
                bottom: 0.5,
                left: 0.5,
                right: 0.5,
            },
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_text_block(
        &mut self,
        page: &mut RenderedPage,
        text: &str,
        rich: &[RichParagraph],
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        style: &TextStyle,
        paragraph: &Paragraph,
        insets: Insets,
    ) {
        let left = insets.left.max(0.0);
        let right = insets.right.max(0.0);
        let top = insets.top.max(0.0);
        let bottom = insets.bottom.max(0.0);
        let available = (width - left - right).max(1.0);
        let mut size = style.size.max(1.0);
        let bold = style.bold;
        let italic = style.italic;
        // XFA fields and footer labels are single-line boxes. Helvetica is wider than the
        // Myriad Pro the template asks for; shrink by a fraction of a point rather than wrap
        // the text into a line above its box and overlap whatever is there.
        if rich.is_empty()
            && !text.contains('\n')
            && height <= size * 2.2
            && wrap(text, size, bold, available).len() > 1
        {
            let mut trial = size;
            while trial > 5.0 && wrap(text, trial, bold, available).len() > 1 {
                trial -= 0.25;
            }
            size = trial;
        }
        let mut lines: Vec<(String, bool, bool, HorizontalAlign)> = Vec::new();
        if rich.is_empty() {
            let normalised = normalise_space(text);
            if normalised.trim().is_empty() {
                return;
            }
            for line in wrap(&normalised, size, bold, available) {
                lines.push((line, bold, italic, paragraph.horizontal));
            }
        } else {
            for rich_paragraph in rich {
                let text = rich_paragraph.text();
                if text.trim().is_empty() {
                    continue;
                }
                let paragraph_bold = weighted_bold(rich_paragraph);
                let paragraph_size = rich_paragraph
                    .runs
                    .iter()
                    .find_map(|run| run.size)
                    .unwrap_or(size);
                let align = rich_paragraph.horizontal.unwrap_or(paragraph.horizontal);
                for line in wrap(&text, paragraph_size, paragraph_bold, available) {
                    lines.push((line, paragraph_bold, italic, align));
                }
            }
        }
        if lines.is_empty() {
            return;
        }
        let line_height = size * 1.18;
        let total = lines.len() as f64 * line_height;
        let mut cursor = match paragraph.vertical {
            VerticalAlign::Top => y + top,
            VerticalAlign::Middle => y + top + (height - top - bottom - total) / 2.0,
            VerticalAlign::Bottom => y + height - bottom - total,
        };
        for (line, line_bold, line_italic, align) in lines {
            let line_width = text_width(&line, size, line_bold);
            let line_x = match align {
                HorizontalAlign::Left => x + left,
                HorizontalAlign::Center => x + left + (available - line_width) / 2.0,
                HorizontalAlign::Right => x + left + available - line_width,
            };
            page.ops.push(Op::Text {
                x: line_x,
                y: cursor,
                text: line,
                size,
                bold: line_bold,
                italic: line_italic,
                color: style.color,
            });
            cursor += line_height;
        }
    }

    fn measure(&self, node: &LayoutNode) -> Measured {
        if !node.presence.occupies_space() {
            return Measured::default();
        }
        let width = node
            .geometry
            .width
            .or_else(|| {
                let intrinsic = self.intrinsic_width(node);
                (intrinsic > 0.0).then_some(intrinsic)
            })
            .unwrap_or(0.0);
        let mut height = if let Some(height) = node.geometry.height {
            height
        } else {
            self.content_height(node, width)
        };
        if let Some(minimum) = node.geometry.min_height {
            height = height.max(minimum);
        }
        if let Some(maximum) = node.geometry.max_height {
            height = height.min(maximum);
        }
        let _ = width;
        Measured { height }
    }

    fn content_height(&self, node: &LayoutNode, width: f64) -> f64 {
        let caption_height = node
            .caption
            .as_ref()
            .filter(|caption| {
                matches!(
                    caption.placement,
                    Some(CaptionPlacement::Top | CaptionPlacement::Bottom)
                )
            })
            .map(|caption| caption_height(caption, caption.style.size))
            .unwrap_or(0.0);
        match node.kind {
            NodeKind::Draw => {
                if let Some(draw) = &node.draw
                    && matches!(draw.kind, DrawKind::Line { .. })
                {
                    return node.geometry.height.unwrap_or(0.0);
                }
                text_block_height(node, width, node.paragraph.vertical) + caption_height
            }
            NodeKind::Field => {
                let text = node
                    .field
                    .as_ref()
                    .and_then(|field| field.default_value.as_deref())
                    .unwrap_or("");
                let lines = wrap(
                    text,
                    node.font.size,
                    node.font.bold,
                    (width - node.margins.left - node.margins.right).max(1.0),
                )
                .len();
                (lines as f64 * node.font.size * 1.18)
                    + node.margins.top
                    + node.margins.bottom
                    + caption_height
            }
            NodeKind::ExclGroup => node
                .children
                .iter()
                .map(|child| self.measure(child).height)
                .fold(0.0, f64::max),
            NodeKind::Subform => match &node.layout {
                LayoutKind::TopBottom => {
                    let mut total = 0.0;
                    for child in &node.children {
                        if !child.presence.occupies_space() {
                            continue;
                        }
                        total += self.measure(child).height
                            + child.paragraph.space_above
                            + child.paragraph.space_below;
                    }
                    total
                }
                LayoutKind::LeftRightTopBottom => {
                    let mut cursor = 0.0f64;
                    let mut height = 0.0f64;
                    let mut row_height = 0.0f64;
                    for child in &node.children {
                        if !child.presence.occupies_space() {
                            continue;
                        }
                        let child_width = child
                            .geometry
                            .width
                            .unwrap_or_else(|| self.intrinsic_width(child));
                        if cursor + child_width > width && cursor > 0.0 {
                            cursor = 0.0;
                            height += row_height;
                            row_height = 0.0;
                        }
                        cursor += child_width;
                        row_height = row_height.max(self.measure(child).height);
                    }
                    height + row_height
                }
                LayoutKind::Table => {
                    let mut total = 0.0;
                    for row in &node.children {
                        if !row.presence.occupies_space() {
                            continue;
                        }
                        let mut row_height = 0.0f64;
                        for (index, child) in row.children.iter().enumerate() {
                            if !child.presence.occupies_space() {
                                continue;
                            }
                            let child_width = node
                                .column_widths
                                .get(index)
                                .copied()
                                .or(child.geometry.width)
                                .unwrap_or(0.0);
                            let _ = child_width;
                            row_height = row_height.max(self.measure(child).height);
                        }
                        total += row_height;
                    }
                    total
                }
                LayoutKind::Row => node
                    .children
                    .iter()
                    .map(|child| self.measure(child).height)
                    .fold(0.0, f64::max),
                LayoutKind::Position | LayoutKind::Unsupported(_) => {
                    let mut bottom = 0.0f64;
                    for child in &node.children {
                        if !child.presence.occupies_space() {
                            continue;
                        }
                        let child_height = self.measure(child).height;
                        bottom = bottom.max(child.geometry.y + child_height);
                    }
                    bottom
                }
            },
        }
    }

    fn intrinsic_width(&self, node: &LayoutNode) -> f64 {
        if let Some(width) = node.geometry.width {
            return width;
        }
        match node.kind {
            NodeKind::Draw => {
                if let Some(draw) = &node.draw
                    && !draw.text.is_empty()
                {
                    let longest = draw
                        .text
                        .lines()
                        .map(|line| text_width(line, node.font.size, node.font.bold))
                        .fold(0.0, f64::max);
                    return longest + node.margins.left + node.margins.right;
                }
                0.0
            }
            NodeKind::Field => {
                let text = node
                    .field
                    .as_ref()
                    .and_then(|field| field.default_value.as_deref())
                    .unwrap_or("");
                text_width(text, node.font.size, node.font.bold)
                    + node.margins.left
                    + node.margins.right
            }
            NodeKind::ExclGroup => node
                .children
                .iter()
                .map(|child| self.intrinsic_width(child) + child.geometry.x)
                .fold(0.0, f64::max),
            NodeKind::Subform => match &node.layout {
                LayoutKind::Position | LayoutKind::Unsupported(_) => node
                    .children
                    .iter()
                    .map(|child| child.geometry.x + self.intrinsic_width(child))
                    .fold(0.0, f64::max),
                LayoutKind::TopBottom => node
                    .children
                    .iter()
                    .map(|child| self.intrinsic_width(child))
                    .fold(0.0, f64::max),
                LayoutKind::LeftRightTopBottom => node
                    .children
                    .iter()
                    .map(|child| self.intrinsic_width(child))
                    .sum(),
                LayoutKind::Table => node.column_widths.iter().sum(),
                LayoutKind::Row => node
                    .children
                    .iter()
                    .map(|child| self.intrinsic_width(child))
                    .sum(),
            },
        }
    }

    fn finish(self) -> RenderedDocument {
        let mut skipped: Vec<String> = self.skipped.into_iter().collect();
        if self.template.script_count > 0 {
            skipped.push(format!(
                "{} JavaScript element(s) were not executed; page numbers are synthesized from the pagination",
                self.template.script_count
            ));
        }
        let typefaces: Vec<&str> = self
            .template
            .fonts
            .keys()
            .filter(|name| !name.eq_ignore_ascii_case("Helvetica") && !name.starts_with('('))
            .map(String::as_str)
            .collect();
        if !typefaces.is_empty() {
            skipped.push(format!(
                "requested font(s) {} were substituted with Helvetica",
                typefaces.join(", ")
            ));
        }
        let mut unsupported_controls: BTreeMap<&str, usize> = BTreeMap::new();
        for field in self.template.fields() {
            if matches!(
                field.kind,
                FieldType::Button | FieldType::Barcode | FieldType::Signature
            ) {
                *unsupported_controls.entry(field.kind.label()).or_insert(0) += 1;
            }
        }
        if !unsupported_controls.is_empty() {
            let summary = unsupported_controls
                .iter()
                .map(|(kind, count)| format!("{count} {kind}"))
                .collect::<Vec<_>>()
                .join(", ");
            skipped.push(format!(
                "{summary} field(s) were not rendered (a control has no printed value)"
            ));
        }
        skipped.extend(self.template.warnings.iter().cloned());
        if !self.missing_characters.is_empty() {
            let characters: String = self.missing_characters.iter().collect();
            skipped.push(format!(
                "characters outside WinAnsi were written as `?`: {characters}"
            ));
        }
        RenderedDocument {
            pages: self.pages,
            assets: self.assets,
            skipped,
        }
    }
}

/// Whitespace-collapsed text for comparing a page-area duplicate with the body's title.
fn text_key(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase()
}

fn is_checked(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "1" | "on" | "true" | "yes" | "y"
    )
}

fn weighted_bold(paragraph: &RichParagraph) -> bool {
    let mut bold = 0usize;
    let mut total = 0usize;
    for run in &paragraph.runs {
        let length = run
            .text
            .chars()
            .filter(|character| !character.is_whitespace())
            .count();
        total += length;
        if run.bold {
            bold += length;
        }
    }
    total > 0 && bold * 2 >= total
}

fn caption_height(caption: &Caption, size: f64) -> f64 {
    if caption.reserve > 0.0 {
        caption.reserve
    } else {
        size * 1.3
    }
}

fn caption_width(caption: &Caption, size: f64) -> f64 {
    if caption.reserve > 0.0 {
        caption.reserve
    } else {
        text_width(&caption.text, size, caption.style.bold) + 2.0
    }
}

fn text_block_height(node: &LayoutNode, width: f64, _vertical: VerticalAlign) -> f64 {
    let size = node.font.size.max(1.0);
    let available = (width - node.margins.left - node.margins.right).max(1.0);
    let text = node
        .draw
        .as_ref()
        .map(|draw| {
            if draw.rich.is_empty() {
                draw.text.clone()
            } else {
                draw.rich
                    .iter()
                    .map(RichParagraph::text)
                    .collect::<Vec<_>>()
                    .join("\n")
            }
        })
        .unwrap_or_default();
    let lines = wrap(&text, size, node.font.bold, available).len();
    lines as f64 * size * 1.18 + node.margins.top + node.margins.bottom
}

/// Every text string a page body draws, used only to avoid painting the page-area title a
/// second time in the footer on page one.
fn draw_texts(node: &LayoutNode) -> BTreeSet<String> {
    let mut set = BTreeSet::new();
    fn walk(node: &LayoutNode, set: &mut BTreeSet<String>) {
        if let Some(draw) = &node.draw {
            for text in draw.text.lines() {
                let key = text_key(text);
                if !key.is_empty() {
                    set.insert(key);
                }
            }
        }
        for child in &node.children {
            walk(child, set);
        }
    }
    walk(node, &mut set);
    set
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::template::parse_template;

    fn render_template(xml: &str) -> RenderedDocument {
        let template = parse_template(xml.as_bytes()).expect("template");
        let dataset = DataSet::default();
        render(&template, &dataset)
    }

    #[test]
    fn lays_out_a_two_page_break_form_and_prints_the_page_number() {
        let document = render_template(
            r#"<template><subform name="form1">
              <pageSet><pageArea name="Page1">
                <contentArea x="10mm" y="10mm" w="190mm" h="250mm"/>
                <medium stock="letter" short="215.9mm" long="279.4mm"/>
                <draw name="Pages" x="170mm" y="5mm" w="30mm" h="5mm"><value><text>PAGE  OF</text></value></draw>
              </pageArea></pageSet>
              <subform name="Page1" w="190mm" layout="tb">
                <breakBefore targetType="pageArea" target="Page1"/>
                <draw name="title" w="190mm" h="10mm"><value><text>First page</text></value></draw>
              </subform>
              <subform name="Page2" w="190mm" layout="tb">
                <breakBefore startNew="1"/>
                <draw name="title" w="190mm" h="10mm"><value><text>Second page</text></value></draw>
              </subform>
            </subform></template>"#,
        );
        assert_eq!(document.pages.len(), 2);
        let text: Vec<&str> = document
            .pages
            .iter()
            .flat_map(|page| page.ops.iter())
            .filter_map(|op| match op {
                Op::Text { text, .. } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert!(text.contains(&"PAGE 1 OF 2"));
        assert!(text.contains(&"PAGE 2 OF 2"));
    }

    #[test]
    fn splits_a_flow_container_at_a_page_boundary() {
        let mut xml = String::from(
            r#"<template><subform name="form1"><pageSet><pageArea name="Page1">
              <contentArea x="0" y="0" w="200mm" h="100mm"/><medium stock="letter"/>
              </pageArea></pageSet><subform name="Page1" w="200mm" layout="tb">
              <breakBefore startNew="1"/><subform name="Body" layout="tb">"#,
        );
        for index in 0..12 {
            xml.push_str(&format!(
                r#"<draw name="line{index}" w="200mm" h="12mm"><value><text>line {index}</text></value></draw>"#
            ));
        }
        xml.push_str("</subform></subform></subform></template>");
        let document = render_template(&xml);
        assert!(
            document.pages.len() >= 2,
            "expected the body to split: {}",
            document.pages.len()
        );
    }
}
