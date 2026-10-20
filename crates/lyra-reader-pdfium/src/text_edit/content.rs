//! Walk a page's content streams and record every glyph with its origin, advance and font.
//!
//! This is deliberately a *reader*: it never rewrites an operator. It tracks the subset of the
//! PDF graphics and text state that decides where a glyph lands (CTM, text matrix, spacing,
//! rise, render mode, clip, pattern fill) and recurses into form XObjects so a page's glyph
//! sequence can be compared one-to-one with PDFium's text page. Text inside a form is recorded
//! but flagged: phase one's rules refuse it for editing.

use super::font::{FontData, FontSubtype};
use super::{TextEditOperator, TextEditRefusalReason};
use lopdf::content::Content;
use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use std::collections::BTreeMap;
use std::sync::Arc;

const IDENTITY: [f64; 6] = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
const MAX_FORM_DEPTH: usize = 12;

pub(crate) const FLAG_IN_FORM: u8 = 1 << 0;
pub(crate) const FLAG_CLIPPED: u8 = 1 << 1;
pub(crate) const FLAG_PATTERN: u8 = 1 << 2;
pub(crate) const FLAG_ROTATED: u8 = 1 << 3;
pub(crate) const FLAG_VERTICAL: u8 = 1 << 4;
pub(crate) const FLAG_INVISIBLE: u8 = 1 << 5;
pub(crate) const FLAG_WIDTH_MISSING: u8 = 1 << 6;
pub(crate) const FLAG_MALFORMED_STRING: u8 = 1 << 7;

/// One glyph produced by a text-showing operator.
pub(crate) struct Glyph {
    pub code: u32,
    /// Decoded text from the font's `/ToUnicode`/encoding; `None` means no mapping is available.
    pub text: Option<String>,
    /// Advance in page units along the baseline.
    pub advance: f64,
    /// Glyph origin (baseline, including text rise) in PDF user space.
    pub origin: [f64; 2],
    /// Effective font size in page units (font size × text-matrix scale).
    pub font_size: f64,
    pub font: Arc<FontData>,
    pub flags: u8,
}

/// A run candidate: one string operand of one text-showing operator. A `TJ` number that separates
/// two strings is a boundary this analysis will not cross.
pub(crate) struct RunCandidate {
    pub start: usize,
    pub end: usize,
    pub operator: TextEditOperator,
    /// True when this run is a string inside a `TJ` array that also carries numeric kerning
    /// adjustments. A conservative phase-two policy refuses these runs.
    pub tj_adjusted: bool,
    pub operator_index: usize,
    pub font: Arc<FontData>,
    pub font_size: f64,
    pub flags: u8,
}

pub(crate) struct ParsedPage {
    pub glyphs: Vec<Glyph>,
    pub runs: Vec<RunCandidate>,
    pub tj_boundaries: usize,
    /// A page-level problem that makes the one-to-one glyph mapping untrustworthy.
    pub problem: Option<TextEditRefusalReason>,
    pub note: Option<String>,
}

/// Parse one page's `/Contents` with its nearest `/Resources` dictionary.
pub(crate) fn parse_page(document: &Document, page_id: ObjectId, content: &[u8]) -> ParsedPage {
    let resources = nearest_resources(document, page_id)
        .map(|dictionary| Resources::read(document, dictionary))
        .unwrap_or_default();
    let mut walker = Walker {
        document,
        glyphs: Vec::new(),
        runs: Vec::new(),
        tj_boundaries: 0,
        problem: None,
        note: None,
        form_stack: Vec::new(),
    };
    walker.walk(content, &resources, IDENTITY, GState::default(), false, 0);
    ParsedPage {
        glyphs: walker.glyphs,
        runs: walker.runs,
        tj_boundaries: walker.tj_boundaries,
        problem: walker.problem,
        note: walker.note,
    }
}

/// The nearest `/Resources` dictionary a page inherits. PDF resource inheritance replaces the
/// whole dictionary, so the first one found is the one that applies.
fn nearest_resources(document: &Document, page_id: ObjectId) -> Option<&Dictionary> {
    let mut current = Some(page_id);
    for _ in 0..64 {
        let id = current?;
        let page = document.get_dictionary(id).ok()?;
        if let Ok(value) = page.get(b"Resources") {
            return resolve_dictionary(document, value);
        }
        current = page
            .get(b"Parent")
            .ok()
            .and_then(|value| value.as_reference().ok());
    }
    None
}

fn resolve_dictionary<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Dictionary> {
    match object {
        Object::Dictionary(dictionary) => Some(dictionary),
        Object::Reference(id) => document.get_dictionary(*id).ok(),
        _ => None,
    }
}

#[derive(Default)]
struct Resources {
    fonts: BTreeMap<Vec<u8>, Arc<FontData>>,
    xobjects: BTreeMap<Vec<u8>, XObject>,
    extgstates: BTreeMap<Vec<u8>, Object>,
    patterns: std::collections::BTreeSet<Vec<u8>>,
}

enum XObject {
    Reference(ObjectId),
    Direct(Box<Stream>),
}

impl Resources {
    fn read(document: &Document, dictionary: &Dictionary) -> Self {
        let mut resources = Self::default();
        if let Some(fonts) = dictionary
            .get(b"Font")
            .ok()
            .and_then(|value| resolve_dictionary(document, value))
        {
            for (name, value) in fonts.iter() {
                if let Some(font) = resolve_dictionary(document, value) {
                    let font = super::font::read_font(document, font);
                    resources.fonts.insert(name.clone(), Arc::new(font));
                }
            }
        }
        if let Some(xobjects) = dictionary
            .get(b"XObject")
            .ok()
            .and_then(|value| resolve_dictionary(document, value))
        {
            for (name, value) in xobjects.iter() {
                let object = match value {
                    Object::Reference(id) => XObject::Reference(*id),
                    Object::Stream(stream) => XObject::Direct(Box::new(stream.clone())),
                    _ => continue,
                };
                resources.xobjects.insert(name.clone(), object);
            }
        }
        if let Some(extgstates) = dictionary
            .get(b"ExtGState")
            .ok()
            .and_then(|value| resolve_dictionary(document, value))
        {
            for (name, value) in extgstates.iter() {
                resources.extgstates.insert(name.clone(), value.clone());
            }
        }
        if let Some(patterns) = dictionary
            .get(b"Pattern")
            .ok()
            .and_then(|value| resolve_dictionary(document, value))
        {
            for name in patterns.iter().map(|(name, _)| name.clone()) {
                resources.patterns.insert(name);
            }
        }
        resources
    }
}

#[derive(Clone)]
struct GState {
    ctm: [f64; 6],
    font: Option<Arc<FontData>>,
    font_size: f64,
    char_spacing: f64,
    word_spacing: f64,
    horizontal_scale: f64,
    leading: f64,
    rise: f64,
    render_mode: i64,
    fill_pattern: bool,
    stroke_pattern: bool,
    fill_space: Option<Vec<u8>>,
    stroke_space: Option<Vec<u8>>,
    clip: bool,
}

impl Default for GState {
    fn default() -> Self {
        Self {
            ctm: IDENTITY,
            font: None,
            font_size: 0.0,
            char_spacing: 0.0,
            word_spacing: 0.0,
            horizontal_scale: 1.0,
            leading: 0.0,
            rise: 0.0,
            render_mode: 0,
            fill_pattern: false,
            stroke_pattern: false,
            fill_space: None,
            stroke_space: None,
            clip: false,
        }
    }
}

struct Walker<'a> {
    document: &'a Document,
    glyphs: Vec<Glyph>,
    runs: Vec<RunCandidate>,
    tj_boundaries: usize,
    problem: Option<TextEditRefusalReason>,
    note: Option<String>,
    form_stack: Vec<ObjectId>,
}

impl Walker<'_> {
    fn fail(&mut self, reason: TextEditRefusalReason, note: impl Into<String>) {
        if self.problem.is_none() {
            self.problem = Some(reason);
            self.note = Some(note.into());
        }
    }

    fn walk(
        &mut self,
        content: &[u8],
        resources: &Resources,
        ctm: [f64; 6],
        initial_state: GState,
        in_form: bool,
        depth: usize,
    ) {
        let content = match Content::decode(content) {
            Ok(content) => content,
            Err(error) => {
                self.fail(
                    TextEditRefusalReason::ContentUnreadable,
                    format!("a content stream could not be parsed: {error}"),
                );
                return;
            }
        };
        let mut state = initial_state;
        state.ctm = ctm;
        let mut text_matrix = IDENTITY;
        let mut line_matrix = IDENTITY;
        let mut stack: Vec<GState> = Vec::new();
        let mut pending_clip = false;

        for (operator_index, operation) in content.operations.iter().enumerate() {
            match operation.operator.as_str() {
                "q" => stack.push(state.clone()),
                "Q" => {
                    if let Some(previous) = stack.pop() {
                        state = previous;
                    }
                }
                "cm" => {
                    if let Some(matrix) = matrix(&operation.operands) {
                        state.ctm = compose(state.ctm, matrix);
                    }
                }
                "BT" => {
                    text_matrix = IDENTITY;
                    line_matrix = IDENTITY;
                }
                "ET" => {}
                "Tf" => {
                    let size = operation.operands.get(1).and_then(number);
                    if let Some(size) = size {
                        state.font_size = size;
                    }
                    if let Some(name) = operation.operands.first().and_then(name_bytes) {
                        state.font =
                            Some(resources.fonts.get(name).cloned().unwrap_or_else(|| {
                                Arc::new(FontData::unknown(
                                    String::from_utf8_lossy(name).into_owned(),
                                ))
                            }));
                    }
                }
                "Tc" => {
                    if let Some(value) = operation.operands.first().and_then(number) {
                        state.char_spacing = value;
                    }
                }
                "Tw" => {
                    if let Some(value) = operation.operands.first().and_then(number) {
                        state.word_spacing = value;
                    }
                }
                "Tz" => {
                    if let Some(value) = operation.operands.first().and_then(number) {
                        state.horizontal_scale = value / 100.0;
                    }
                }
                "TL" => {
                    if let Some(value) = operation.operands.first().and_then(number) {
                        state.leading = value;
                    }
                }
                "Ts" => {
                    if let Some(value) = operation.operands.first().and_then(number) {
                        state.rise = value;
                    }
                }
                "Tr" => {
                    if let Some(value) = operation.operands.first().and_then(integer) {
                        state.render_mode = value;
                    }
                }
                "Td" => {
                    if let Some((tx, ty)) = pair(&operation.operands) {
                        line_matrix = compose(line_matrix, translate(tx, ty));
                        text_matrix = line_matrix;
                    }
                }
                "TD" => {
                    if let Some((tx, ty)) = pair(&operation.operands) {
                        state.leading = -ty;
                        line_matrix = compose(line_matrix, translate(tx, ty));
                        text_matrix = line_matrix;
                    }
                }
                "Tm" => {
                    if let Some(matrix) = matrix(&operation.operands) {
                        text_matrix = matrix;
                        line_matrix = matrix;
                    }
                }
                "T*" => {
                    line_matrix = compose(line_matrix, translate(0.0, -state.leading));
                    text_matrix = line_matrix;
                }
                "Tj" | "'" | "\"" => {
                    if operation.operator == "'" || operation.operator == "\"" {
                        if operation.operator == "\"" {
                            if let Some(word) = operation.operands.first().and_then(number) {
                                state.word_spacing = word;
                            }
                            if let Some(character) = operation.operands.get(1).and_then(number) {
                                state.char_spacing = character;
                            }
                        }
                        line_matrix = compose(line_matrix, translate(0.0, -state.leading));
                        text_matrix = line_matrix;
                    }
                    let index = if operation.operator == "\"" { 2 } else { 0 };
                    if let Some(string) = operation.operands.get(index).and_then(string_bytes) {
                        self.show_string(
                            string,
                            operation.operator.as_str(),
                            operator_index,
                            &mut state,
                            &mut text_matrix,
                            in_form,
                        );
                    }
                }
                "TJ" => {
                    let Some(array) = operation
                        .operands
                        .first()
                        .and_then(|value| value.as_array().ok())
                    else {
                        continue;
                    };
                    let tj_adjusted = array.iter().any(|item| number(item).is_some());
                    for item in array {
                        match item {
                            Object::String(bytes, _) => {
                                let start = self.glyphs.len();
                                self.show_glyphs(bytes, &mut state, &mut text_matrix, in_form);
                                if self.glyphs.len() > start {
                                    // Each string is its own run; a numeric adjustment ends it.
                                    self.push_run(
                                        start,
                                        self.glyphs.len(),
                                        TextEditOperator::TjArrayString,
                                        tj_adjusted,
                                        operator_index,
                                        &state,
                                    );
                                }
                            }
                            other => {
                                if let Some(adjustment) = number(other) {
                                    self.tj_boundaries += 1;
                                    let shift = -adjustment / 1000.0
                                        * state.font_size
                                        * state.horizontal_scale;
                                    text_matrix = compose(text_matrix, translate(shift, 0.0));
                                }
                            }
                        }
                    }
                }
                "gs" => {
                    if let Some(name) = operation.operands.first().and_then(name_bytes) {
                        self.apply_extgstate(name, resources, &mut state);
                    }
                }
                "cs" | "CS" => {
                    let name = operation
                        .operands
                        .first()
                        .and_then(name_bytes)
                        .map(<[u8]>::to_vec);
                    if operation.operator == "cs" {
                        state.fill_space = name;
                    } else {
                        state.stroke_space = name;
                    }
                }
                "scn" | "SCN" => {
                    let pattern = operation
                        .operands
                        .iter()
                        .rev()
                        .find_map(name_bytes)
                        .is_some();
                    let space = if operation.operator == "scn" {
                        &state.fill_space
                    } else {
                        &state.stroke_space
                    };
                    let is_pattern = space.as_deref() == Some(b"Pattern");
                    if is_pattern && pattern {
                        if operation.operator == "scn" {
                            state.fill_pattern = true;
                        } else {
                            state.stroke_pattern = true;
                        }
                    } else if operation.operator == "scn" {
                        state.fill_pattern = false;
                    } else {
                        state.stroke_pattern = false;
                    }
                }
                "g" | "rg" | "k" | "sc" => state.fill_pattern = false,
                "G" | "RG" | "K" | "SC" => state.stroke_pattern = false,
                "W" | "W*" => pending_clip = true,
                "S" | "s" | "f" | "F" | "f*" | "B" | "B*" | "b" | "b*" | "n" => {
                    if pending_clip {
                        state.clip = true;
                        pending_clip = false;
                    }
                }
                "Do" => {
                    if let Some(name) = operation.operands.first().and_then(name_bytes) {
                        self.do_xobject(name, resources, &state, depth);
                    }
                }
                _ => {}
            }
        }
    }

    fn apply_extgstate(&mut self, name: &[u8], resources: &Resources, state: &mut GState) {
        let Some(value) = resources.extgstates.get(name) else {
            return;
        };
        let Some(dictionary) = resolve_dictionary(self.document, value) else {
            return;
        };
        let Ok(font) = dictionary.get(b"Font") else {
            return;
        };
        let Some(array) = font.as_array().ok() else {
            return;
        };
        let Some(font_name) = array.first().and_then(name_bytes) else {
            return;
        };
        state.font = Some(resources.fonts.get(font_name).cloned().unwrap_or_else(|| {
            Arc::new(FontData::unknown(
                String::from_utf8_lossy(font_name).into_owned(),
            ))
        }));
        if let Some(size) = array.get(1).and_then(number) {
            state.font_size = size;
        }
    }

    fn do_xobject(&mut self, name: &[u8], resources: &Resources, state: &GState, depth: usize) {
        let Some(xobject) = resources.xobjects.get(name) else {
            return;
        };
        let stream = match xobject {
            XObject::Reference(id) => self
                .document
                .get_object(*id)
                .ok()
                .and_then(|object| object.as_stream().ok()),
            XObject::Direct(stream) => Some(stream.as_ref()),
        };
        let Some(stream) = stream else {
            return;
        };
        let subtype = stream
            .dict
            .get(b"Subtype")
            .ok()
            .and_then(name_bytes)
            .unwrap_or_default();
        if subtype != b"Form" {
            return;
        }
        if stream.dict.get(b"FormType").ok().and_then(integer) == Some(2) {
            self.fail(
                TextEditRefusalReason::UnsupportedContent,
                "a PostScript form XObject cannot be analysed",
            );
            return;
        }
        if depth >= MAX_FORM_DEPTH {
            self.fail(
                TextEditRefusalReason::UnsupportedContent,
                "form XObjects are nested more deeply than this analysis reads",
            );
            return;
        }
        if let XObject::Reference(id) = xobject {
            if self.form_stack.contains(id) {
                self.fail(
                    TextEditRefusalReason::UnsupportedContent,
                    "a form XObject references itself",
                );
                return;
            }
            self.form_stack.push(*id);
        }
        let content = stream
            .decompressed_content()
            .unwrap_or_else(|_| stream.content.clone());
        let matrix = stream
            .dict
            .get(b"Matrix")
            .ok()
            .and_then(|value| value.as_array().ok())
            .and_then(|value| matrix(value))
            .unwrap_or(IDENTITY);
        let ctm = compose(state.ctm, matrix);
        let form_resources = stream
            .dict
            .get(b"Resources")
            .ok()
            .and_then(|value| resolve_dictionary(self.document, value))
            .map(|dictionary| Resources::read(self.document, dictionary))
            .unwrap_or_default();
        let mut form_state = state.clone();
        form_state.clip = true;
        self.walk(&content, &form_resources, ctm, form_state, true, depth + 1);
        if matches!(xobject, XObject::Reference(_)) {
            self.form_stack.pop();
        }
    }

    fn show_string(
        &mut self,
        bytes: &[u8],
        operator: &str,
        operator_index: usize,
        state: &mut GState,
        text_matrix: &mut [f64; 6],
        in_form: bool,
    ) {
        let start = self.glyphs.len();
        self.show_glyphs(bytes, state, text_matrix, in_form);
        if self.glyphs.len() == start {
            return;
        }
        let kind = match operator {
            "'" => TextEditOperator::TjQuote,
            "\"" => TextEditOperator::TjDoubleQuote,
            _ => TextEditOperator::Tj,
        };
        self.push_run(start, self.glyphs.len(), kind, false, operator_index, state);
    }

    fn show_glyphs(
        &mut self,
        bytes: &[u8],
        state: &mut GState,
        text_matrix: &mut [f64; 6],
        in_form: bool,
    ) {
        let Some(font) = state.font.clone() else {
            return;
        };
        let code_bytes = usize::from(font.code_bytes);
        if code_bytes == 0 {
            return;
        }
        let malformed = !bytes.len().is_multiple_of(code_bytes);
        let count = bytes.len() / code_bytes;
        for index in 0..count {
            let code = match code_bytes {
                1 => u32::from(bytes[index]),
                _ => u32::from(u16::from_be_bytes([bytes[index * 2], bytes[index * 2 + 1]])),
            };
            let text = font.code_to_text.get(&code).cloned();
            let width = font.widths.get(code);
            let combined = compose(state.ctm, *text_matrix);
            let scale = (combined[0] * combined[0] + combined[1] * combined[1]).sqrt();
            let horizontal = combined[1].abs() <= 1e-6 * scale.max(1.0)
                && combined[2].abs() <= 1e-6 * scale.max(1.0)
                && combined[0] > 0.0;
            let origin = apply(combined, 0.0, state.rise);
            let word_spacing = if code_bytes == 1 && code == 32 {
                state.word_spacing
            } else {
                0.0
            };
            let advance = ((width.unwrap_or(0.0) / 1000.0) * state.font_size
                + state.char_spacing
                + word_spacing)
                * state.horizontal_scale;
            let advance_page = advance * scale;

            let mut flags = 0u8;
            if in_form {
                flags |= FLAG_IN_FORM;
            }
            if state.clip {
                flags |= FLAG_CLIPPED;
            }
            if (state.fill_pattern && render_uses_fill(state.render_mode))
                || (state.stroke_pattern && render_uses_stroke(state.render_mode))
            {
                flags |= FLAG_PATTERN;
            }
            if !horizontal || state.horizontal_scale <= 0.0 || !scale.is_finite() {
                flags |= FLAG_ROTATED;
            }
            if font.vertical
                || font.subtype == FontSubtype::Type0 && font.encoding_label == "Identity-V"
            {
                flags |= FLAG_VERTICAL;
            }
            if matches!(state.render_mode, 3 | 7) {
                flags |= FLAG_INVISIBLE;
            }
            if width.is_none() {
                flags |= FLAG_WIDTH_MISSING;
            }
            if malformed {
                flags |= FLAG_MALFORMED_STRING;
            }
            self.glyphs.push(Glyph {
                code,
                text,
                advance: advance_page,
                origin,
                font_size: state.font_size * scale,
                font: font.clone(),
                flags,
            });
            *text_matrix = compose(*text_matrix, translate(advance, 0.0));
        }
    }

    fn push_run(
        &mut self,
        start: usize,
        end: usize,
        operator: TextEditOperator,
        tj_adjusted: bool,
        operator_index: usize,
        state: &GState,
    ) {
        if start >= end {
            return;
        }
        let mut flags = 0u8;
        for glyph in &self.glyphs[start..end] {
            flags |= glyph.flags;
        }
        self.runs.push(RunCandidate {
            start,
            end,
            operator,
            tj_adjusted,
            operator_index,
            font: state
                .font
                .clone()
                .unwrap_or_else(|| Arc::new(FontData::unknown("(no font selected)".into()))),
            font_size: self.glyphs[start].font_size,
            flags,
        });
    }
}

fn render_uses_fill(mode: i64) -> bool {
    matches!(mode, 0 | 2 | 4 | 5 | 6)
}

fn render_uses_stroke(mode: i64) -> bool {
    matches!(mode, 1 | 2 | 5 | 6)
}

fn compose(outer: [f64; 6], inner: [f64; 6]) -> [f64; 6] {
    [
        outer[0] * inner[0] + outer[2] * inner[1],
        outer[1] * inner[0] + outer[3] * inner[1],
        outer[0] * inner[2] + outer[2] * inner[3],
        outer[1] * inner[2] + outer[3] * inner[3],
        outer[0] * inner[4] + outer[2] * inner[5] + outer[4],
        outer[1] * inner[4] + outer[3] * inner[5] + outer[5],
    ]
}

fn translate(x: f64, y: f64) -> [f64; 6] {
    [1.0, 0.0, 0.0, 1.0, x, y]
}

fn apply(matrix: [f64; 6], x: f64, y: f64) -> [f64; 2] {
    [
        matrix[0] * x + matrix[2] * y + matrix[4],
        matrix[1] * x + matrix[3] * y + matrix[5],
    ]
}

fn number(object: &Object) -> Option<f64> {
    match object {
        Object::Integer(value) => Some(*value as f64),
        Object::Real(value) => Some(f64::from(*value)),
        _ => None,
    }
}

fn integer(object: &Object) -> Option<i64> {
    match object {
        Object::Integer(value) => Some(*value),
        Object::Real(value) => Some(f64::from(*value) as i64),
        _ => None,
    }
}

fn name_bytes(object: &Object) -> Option<&[u8]> {
    object.as_name().ok()
}

fn string_bytes(object: &Object) -> Option<&[u8]> {
    object.as_str().ok()
}

fn pair(operands: &[Object]) -> Option<(f64, f64)> {
    Some((number(operands.first()?)?, number(operands.get(1)?)?))
}

fn matrix(operands: &[Object]) -> Option<[f64; 6]> {
    if operands.len() < 6 {
        return None;
    }
    let values: Vec<f64> = operands.iter().take(6).filter_map(number).collect();
    if values.len() == 6 {
        Some([
            values[0], values[1], values[2], values[3], values[4], values[5],
        ])
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compose_applies_inner_then_outer() {
        // Translate by (10, 20), then scale by 2: a point at the origin lands at (20, 40).
        let outer = [2.0, 0.0, 0.0, 2.0, 0.0, 0.0];
        let inner = translate(10.0, 20.0);
        let combined = compose(outer, inner);
        assert_eq!(apply(combined, 0.0, 0.0), [20.0, 40.0]);
    }

    #[test]
    fn render_modes_split_fill_and_stroke() {
        assert!(render_uses_fill(0));
        assert!(!render_uses_fill(1));
        assert!(render_uses_stroke(1));
        assert!(render_uses_fill(2) && render_uses_stroke(2));
        assert!(!render_uses_fill(7));
    }
}
