use super::*;
use lopdf::{Dictionary, Document, Object};

fn annotations(doc: &Document, page: lopdf::ObjectId) -> Result<Vec<Object>> {
    let dictionary = doc.get_dictionary(page).map_err(pdf_error)?;
    match dictionary.get(b"Annots") {
        Ok(value) => Ok(doc
            .dereference(value)
            .map_err(pdf_error)?
            .1
            .as_array()
            .map_err(pdf_error)?
            .clone()),
        Err(_) => Ok(Vec::new()),
    }
}
fn dictionary(doc: &Document, value: &Object) -> Result<Dictionary> {
    doc.dereference(value)
        .map_err(pdf_error)?
        .1
        .as_dict()
        .cloned()
        .map_err(pdf_error)
}

pub(super) fn append(source: &Path, index: u32, page: &mut ContentPage) -> Result<()> {
    let doc = Document::load(source).map_err(pdf_error)?;
    let page_id = doc.get_pages()[&(index + 1)];
    let backend = crate::PdfiumBackend::open(source, None)?;
    let targets = backend.link_targets(PageIndex(index))?;
    for (index, object) in annotations(&doc, page_id)?.iter().enumerate() {
        let annotation = dictionary(&doc, object)?;
        if annotation.get(b"Subtype").and_then(Object::as_name).ok() != Some(b"Link") {
            continue;
        }
        let Ok(rect) = annotation.get(b"Rect").and_then(Object::as_array) else {
            continue;
        };
        if rect.len() != 4 {
            continue;
        }
        let values: Vec<_> = rect
            .iter()
            .map(|v| v.as_float())
            .collect::<std::result::Result<_, _>>()
            .map_err(pdf_error)?;
        let bounds = ContentBox {
            x: f64::from(values[0].min(values[2])),
            y: f64::from(values[1].min(values[3])),
            width: f64::from((values[2] - values[0]).abs()),
            height: f64::from((values[3] - values[1]).abs()),
        };
        if !bounds.valid() {
            continue;
        }
        let target = targets.iter().find(|t| {
            (t.rect.origin.x - bounds.x).abs() < 0.5
                && (t.rect.origin.y - bounds.y).abs() < 0.5
                && (t.rect.size.width - bounds.width).abs() < 0.5
        });
        let link_page = target.and_then(|t| t.page.map(|p| p.0));
        let link_uri = target.and_then(|t| t.uri.clone());
        let text = if let Some(page) = link_page {
            format!("to Page {}", page + 1)
        } else {
            link_uri
                .clone()
                .unwrap_or_else(|| "Other destination".into())
        };
        page.items.push(ContentItem {
            id: format!("link:{index}"),
            kind: "link".into(),
            bounds,
            text,
            font: String::new(),
            size: 10.0,
            colour: [40, 140, 255, 255],
            can_edit_text: false,
            reason: None,
            paths: Vec::new(),
            baseline: 0.0,
            link_page,
            link_uri,
        });
    }
    Ok(())
}

pub(super) fn rewrite(
    bytes: &[u8],
    index: u32,
    command: &ContentCommand,
    item: Option<&ContentItem>,
) -> Result<Vec<u8>> {
    let mut doc = Document::load_mem(bytes).map_err(pdf_error)?;
    let page_id = doc.get_pages()[&(index + 1)];
    let mut annots = annotations(&doc, page_id)?;
    let slot = item
        .map(|i| {
            i.id.strip_prefix("link:")
                .and_then(|s| s.parse::<usize>().ok())
                .ok_or_else(|| failure("Select a link annotation."))
        })
        .transpose()?;
    if slot.is_some_and(|i| i >= annots.len()) {
        return Err(failure("The link no longer exists."));
    }
    let mut annotation = slot
        .map(|i| dictionary(&doc, &annots[i]))
        .transpose()?
        .unwrap_or_default();
    match command {
        ContentCommand::Delete { .. } => {
            annots.remove(slot.ok_or_else(|| failure("No link selected."))?);
        }
        ContentCommand::SetLink {
            bounds, page, uri, ..
        } => {
            if page.is_some() == uri.is_some() {
                return Err(failure("Choose either a document page or a URL."));
            }
            annotation.set("Type", Object::Name(b"Annot".to_vec()));
            annotation.set("Subtype", Object::Name(b"Link".to_vec()));
            annotation.remove(b"Dest");
            annotation.remove(b"A");
            annotation.remove(b"AA");
            if let Some(page) = page {
                let destination = doc
                    .get_pages()
                    .get(&(page + 1))
                    .copied()
                    .ok_or_else(|| failure("The destination page is outside the document."))?;
                annotation.set(
                    "Dest",
                    vec![
                        Object::Reference(destination),
                        Object::Name(b"Fit".to_vec()),
                    ],
                );
            } else if let Some(uri) = uri {
                if uri.len() > 8192
                    || !["https:", "http:", "mailto:", "tel:", "ftp:"]
                        .iter()
                        .any(|scheme| uri.to_ascii_lowercase().starts_with(scheme))
                {
                    return Err(failure("Enter an http, https, mailto, tel or ftp URL."));
                }
                let mut action = Dictionary::new();
                action.set("S", Object::Name(b"URI".to_vec()));
                action.set("URI", Object::string_literal(uri.as_str()));
                annotation.set("A", action);
            }
            set_bounds(&mut annotation, *bounds);
            if slot.is_none() {
                annotation.set("Border", vec![0.into(), 0.into(), 0.into()]);
            }
            let id = doc.add_object(annotation);
            if let Some(slot) = slot {
                annots[slot] = id.into()
            } else {
                annots.push(id.into())
            }
        }
        ContentCommand::Transform {
            bounds, rotation, ..
        } => {
            if rotation.abs() > 0.001 {
                return Err(failure("Link regions use an axis-aligned rectangle."));
            }
            set_bounds(&mut annotation, *bounds);
            let id = doc.add_object(annotation);
            annots[slot.ok_or_else(|| failure("No link selected."))?] = id.into();
        }
        _ => return Err(failure("This command does not edit a link.")),
    }
    doc.get_dictionary_mut(page_id)
        .map_err(pdf_error)?
        .set("Annots", annots);
    let mut output = Vec::new();
    doc.save_to(&mut output).map_err(pdf_error)?;
    Ok(output)
}
fn set_bounds(annotation: &mut Dictionary, bounds: ContentBox) {
    annotation.set(
        "Rect",
        vec![
            Object::Real(bounds.x as f32),
            Object::Real(bounds.y as f32),
            Object::Real(bounds.right() as f32),
            Object::Real(bounds.top() as f32),
        ],
    );
    annotation.remove(b"QuadPoints");
    annotation.remove(b"AP");
}
