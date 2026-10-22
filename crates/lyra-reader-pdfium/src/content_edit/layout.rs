//! Keep the user's text frame, not just its current ink bounds. A short edit should not make
//! the next edit wrap into a one-word box. This private PDF page entry carries geometry and a
//! digest only; the text remains exclusively in ordinary PDF content streams.
use super::*;
use lopdf::{Document, Object};

pub(crate) const KEY: &[u8] = b"LyraReaderTextFrames";
#[derive(Serialize, Deserialize)]
pub(super) struct Frame {
    digest: String,
    bounds: ContentBox,
    #[serde(default)]
    lines: Vec<String>,
}

pub(super) fn frames(bytes: &[u8], index: u32) -> Result<Vec<Frame>> {
    let document = Document::load_mem(bytes).map_err(pdf_error)?;
    let page = document
        .get_pages()
        .get(&index.saturating_add(1))
        .copied()
        .ok_or_else(|| failure("The requested page does not exist."))?;
    Ok(read(&document, page))
}

/// Match the writer's individual lines before spatial paragraph grouping. Hashes contain no
/// original plaintext and never override the independently extracted text or its font.
pub(super) fn take_frames(
    items: &mut Vec<ContentItem>,
    frames: &[Frame],
    sheet: Transform2D,
) -> Vec<ContentItem> {
    let mut result = Vec::new();
    for frame in frames.iter().filter(|frame| !frame.lines.is_empty()) {
        let bounds: ContentBox = sheet.apply_rect(frame.bounds.rect()).into();
        let mut chosen = Vec::new();
        for line in &frame.lines {
            let found = items.iter().enumerate().find(|(index, item)| {
                !chosen.contains(index)
                    && item.kind == "text"
                    && item.can_edit_text
                    && digest(&item.text) == *line
                    && contains(bounds, item.bounds)
            });
            let Some((index, _)) = found else { break };
            chosen.push(index);
        }
        if chosen.len() != frame.lines.len() {
            continue;
        }
        let mut grouped = items[chosen[0]].clone();
        for index in chosen.iter().skip(1) {
            merge_item(&mut grouped, items[*index].clone(), "\n")
        }
        if digest(&grouped.text) != frame.digest {
            continue;
        }
        grouped.bounds = bounds;
        let mut index = 0;
        items.retain(|_| {
            let keep = !chosen.contains(&index);
            index += 1;
            keep
        });
        result.push(grouped);
    }
    result
}

fn digest(text: &str) -> String {
    fingerprint(
        text.chars()
            .filter(|c| !c.is_whitespace())
            .collect::<String>()
            .as_bytes(),
    )
}
fn read(document: &Document, page: lopdf::ObjectId) -> Vec<Frame> {
    let Some(bytes) = document
        .get_dictionary(page)
        .ok()
        .and_then(|p| p.get(KEY).ok())
        .and_then(|v| v.as_str().ok())
    else {
        return Vec::new();
    };
    if bytes.len() > 1_000_000 {
        return Vec::new();
    }
    serde_json::from_slice::<Vec<Frame>>(bytes)
        .unwrap_or_default()
        .into_iter()
        .filter(|f| f.bounds.valid())
        .take(1000)
        .collect()
}
fn contains(frame: ContentBox, ink: ContentBox) -> bool {
    ink.x >= frame.x - 4.0
        && ink.y >= frame.y - 4.0
        && ink.right() <= frame.right() + 4.0
        && ink.top() <= frame.top() + 4.0
}
pub(super) fn apply(bytes: &[u8], snapshot: &mut ContentPage) -> Result<()> {
    let document = Document::load_mem(bytes).map_err(pdf_error)?;
    let page = document.get_pages()[&(snapshot.page + 1)];
    for frame in read(&document, page) {
        if let Some(item) = snapshot.items.iter_mut().find(|i| {
            i.kind == "text"
                && i.can_edit_text
                && digest(&i.text) == frame.digest
                && contains(frame.bounds, i.bounds)
        }) {
            item.bounds = frame.bounds;
        }
    }
    Ok(())
}
pub(super) fn update(
    document: &mut Document,
    index: u32,
    command: &ContentCommand,
    item: Option<&ContentItem>,
    written_lines: &[String],
) -> Result<()> {
    let page = document.get_pages()[&(index + 1)];
    let mut frames = read(document, page);
    if let Some(item) = item.filter(|i| i.kind == "text") {
        let old_digest = digest(&item.text);
        frames.retain(|f| f.digest != old_digest || !contains(f.bounds, item.bounds));
    }
    match command {
        ContentCommand::ReplaceText { text, bounds, .. }
        | ContentCommand::InsertText { text, bounds, .. }
            if !text.trim().is_empty() =>
        {
            frames.push(Frame {
                digest: digest(text),
                bounds: *bounds,
                lines: written_lines.iter().map(|line| digest(line)).collect(),
            })
        }
        ContentCommand::Transform {
            bounds, rotation, ..
        } if item.is_some_and(|i| i.kind == "text" && i.can_edit_text)
            && rotation.abs() < 0.001 =>
        {
            frames.push(Frame {
                digest: digest(&item.unwrap().text),
                bounds: *bounds,
                lines: item.unwrap().text.lines().map(digest).collect(),
            })
        }
        _ => {}
    }
    let dictionary = document.get_dictionary_mut(page).map_err(pdf_error)?;
    if frames.is_empty() {
        dictionary.remove(KEY);
    } else {
        dictionary.set(
            KEY.to_vec(),
            Object::string_literal(serde_json::to_vec(&frames).map_err(pdf_error)?),
        );
    }
    Ok(())
}
