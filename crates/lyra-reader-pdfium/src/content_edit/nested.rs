//! PDFium does not serialize edits to a form's child objects when generating its parent page.
//! Edit the form as page content, then install a new form for this one `Do` occurrence. Each
//! ancestor is copied independently, so another placement of a shared form stays untouched.
use super::*;
use lopdf::content::{Content, Operation};
use lopdf::{Dictionary, Document, Object, ObjectId, Stream};
use std::collections::BTreeMap;

pub(super) fn rewrite_path(
    bytes: &[u8],
    index: u32,
    path: &[usize],
    matrix: PdfMatrix,
) -> Result<Vec<u8>> {
    let (parent_matrix, count) = object_info(bytes, index, path[0])?;
    let mut document = Document::load_mem(bytes).map_err(pdf_error)?;
    let page_id = document.get_pages()[&(index + 1)];
    let content = document.get_page_content(page_id);
    let mut content = Content::decode(&content).map_err(pdf_error)?;
    let paints: Vec<_> = content
        .operations
        .iter()
        .enumerate()
        .filter(|(_, op)| {
            matches!(
                op.operator.as_str(),
                "Tj" | "TJ"
                    | "'"
                    | "\""
                    | "Do"
                    | "sh"
                    | "S"
                    | "s"
                    | "f"
                    | "F"
                    | "f*"
                    | "B"
                    | "B*"
                    | "b"
                    | "b*"
            )
        })
        .map(|(i, _)| i)
        .collect();
    if paints.len() != count {
        return Err(failure(
            "The form's operators cannot be mapped reliably to page objects.",
        ));
    }
    if path.len() == 1 {
        let paint = paints[path[0]];
        let mut ctm = PdfMatrix::IDENTITY;
        let mut stack = Vec::new();
        for op in &content.operations[..paint] {
            match op.operator.as_str() {
                "q" => stack.push(ctm),
                "Q" => {
                    ctm = stack
                        .pop()
                        .ok_or_else(|| failure("Unbalanced graphic state"))?
                }
                "cm" if op.operands.len() == 6 => {
                    let v: Vec<f32> = op
                        .operands
                        .iter()
                        .map(|v| v.as_float().map_err(pdf_error))
                        .collect::<Result<_>>()?;
                    ctm = PdfMatrix::new(v[0], v[1], v[2], v[3], v[4], v[5]).multiply(ctm);
                }
                _ => {}
            }
        }
        if ctm.determinant().abs() < 1e-10 {
            return Err(failure("The label's graphic transform is singular."));
        }
        let local = ctm.multiply(matrix).multiply(ctm.invert());
        let op = content.operations[paint].clone();
        let operands = [
            local.a(),
            local.b(),
            local.c(),
            local.d(),
            local.e(),
            local.f(),
        ]
        .into_iter()
        .map(Object::Real)
        .collect();
        content.operations.splice(
            paint..=paint,
            [
                Operation::new("q", vec![]),
                Operation::new("cm", operands),
                op,
                Operation::new("Q", vec![]),
            ],
        );
        let stream = document.add_object(Stream::new(
            Dictionary::new(),
            content.encode().map_err(pdf_error)?,
        ));
        document
            .get_dictionary_mut(page_id)
            .map_err(pdf_error)?
            .set("Contents", stream);
        let mut output = Vec::new();
        document.save_to(&mut output).map_err(pdf_error)?;
        return Ok(output);
    }
    let operation = &content.operations[paints[path[0]]];
    if operation.operator != "Do" {
        return Err(failure("The selected parent is no longer a form."));
    }
    let name = operation
        .operands
        .first()
        .and_then(|o| o.as_name().ok())
        .ok_or_else(|| failure("The form resource name is missing."))?;
    let mut resources = page_resources(&document, page_id)?;
    let mut xobjects =
        resolve_dictionary(&document, resources.get(b"XObject").map_err(pdf_error)?)?;
    let form_id = xobjects
        .get(name)
        .map_err(pdf_error)?
        .as_reference()
        .map_err(pdf_error)?;
    let form = document
        .get_object(form_id)
        .map_err(pdf_error)?
        .as_stream()
        .map_err(pdf_error)?
        .clone();
    if form.dict.get(b"Subtype").and_then(Object::as_name).ok() != Some(b"Form") {
        return Err(failure("The selected object is not a form."));
    }
    let form_resources = form
        .dict
        .get(b"Resources")
        .ok()
        .map(|o| resolve_dictionary(&document, o))
        .transpose()?
        .unwrap_or_else(|| resources.clone());
    let bbox = form.dict.get(b"BBox").map_err(pdf_error)?.clone();
    let mut auxiliary = document.clone();
    let page = auxiliary.get_dictionary_mut(page_id).map_err(pdf_error)?;
    page.set("Contents", form_id);
    page.set("Resources", form_resources);
    page.set("MediaBox", bbox.clone());
    page.set("CropBox", bbox);
    page.set("Rotate", 0);
    page.remove(b"Annots");
    let mut aux_bytes = Vec::new();
    auxiliary.save_to(&mut aux_bytes).map_err(pdf_error)?;
    let local = parent_matrix
        .multiply(matrix)
        .multiply(parent_matrix.invert());
    let edited = rewrite_path(&aux_bytes, index, &path[1..], local)?;
    let edited = Document::load_mem(&edited).map_err(pdf_error)?;
    let edited_page = edited.get_pages()[&(index + 1)];
    let mut dictionary = form.dict.clone();
    dictionary.remove(b"Filter");
    dictionary.remove(b"DecodeParms");
    let edited_resources = Object::Dictionary(page_resources(&edited, edited_page)?);
    let imported = import_object(
        &edited,
        &mut document,
        &edited_resources,
        &mut BTreeMap::new(),
    )?;
    dictionary.set("Resources", imported);
    let replacement = document.add_object(Stream::new(
        dictionary,
        edited.get_page_content(edited_page),
    ));
    let unique = format!("LyraEdit{}", replacement.0).into_bytes();
    xobjects.set(unique.clone(), replacement);
    resources.set("XObject", xobjects);
    content.operations[paints[path[0]]].operands[0] = Object::Name(unique);
    let stream = document.add_object(Stream::new(
        Dictionary::new(),
        content.encode().map_err(pdf_error)?,
    ));
    let page = document.get_dictionary_mut(page_id).map_err(pdf_error)?;
    page.set("Resources", resources);
    page.set("Contents", stream);
    let mut output = Vec::new();
    document.save_to(&mut output).map_err(pdf_error)?;
    Ok(output)
}

fn object_info(bytes: &[u8], index: u32, target: usize) -> Result<(PdfMatrix, usize)> {
    let pdfium = pdfium_instance()?;
    let _guard = PDFIUM_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let doc = pdfium
        .load_pdf_from_byte_slice(bytes, None)
        .map_err(pdf_error)?;
    let page = doc
        .pages()
        .get(index.try_into().map_err(pdf_error)?)
        .map_err(pdf_error)?;
    let object = page.objects().get(target).map_err(pdf_error)?;
    let parent = object
        .as_x_object_form_object()
        .map(|o| o.matrix())
        .transpose()
        .map_err(pdf_error)?
        .unwrap_or(PdfMatrix::IDENTITY);
    Ok((parent, page.objects().len()))
}

fn resolve_dictionary(doc: &Document, object: &Object) -> Result<Dictionary> {
    doc.dereference(object)
        .map_err(pdf_error)?
        .1
        .as_dict()
        .cloned()
        .map_err(pdf_error)
}
pub(super) fn page_resources(doc: &Document, mut page: ObjectId) -> Result<Dictionary> {
    for _ in 0..64 {
        let dict = doc.get_dictionary(page).map_err(pdf_error)?;
        if let Ok(value) = dict.get(b"Resources") {
            return resolve_dictionary(doc, value);
        }
        page = dict
            .get(b"Parent")
            .and_then(Object::as_reference)
            .map_err(pdf_error)?;
    }
    Err(failure("The resource inheritance is cyclic."))
}
fn import_object(
    source: &Document,
    target: &mut Document,
    value: &Object,
    map: &mut BTreeMap<ObjectId, ObjectId>,
) -> Result<Object> {
    Ok(match value {
        Object::Reference(id) => {
            if let Some(copied) = map.get(id) {
                return Ok(Object::Reference(*copied));
            }
            let copied = target.new_object_id();
            map.insert(*id, copied);
            let object = import_object(
                source,
                target,
                source.get_object(*id).map_err(pdf_error)?,
                map,
            )?;
            target.objects.insert(copied, object);
            Object::Reference(copied)
        }
        Object::Array(values) => Object::Array(
            values
                .iter()
                .map(|v| import_object(source, target, v, map))
                .collect::<Result<Vec<_>>>()?,
        ),
        Object::Dictionary(dict) => {
            Object::Dictionary(import_dictionary(source, target, dict, map)?)
        }
        Object::Stream(stream) => Object::Stream(Stream::new(
            import_dictionary(source, target, &stream.dict, map)?,
            stream.content.clone(),
        )),
        other => other.clone(),
    })
}
fn import_dictionary(
    source: &Document,
    target: &mut Document,
    dict: &Dictionary,
    map: &mut BTreeMap<ObjectId, ObjectId>,
) -> Result<Dictionary> {
    let mut out = Dictionary::new();
    for (key, value) in dict.iter() {
        out.set(key.clone(), import_object(source, target, value, map)?)
    }
    Ok(out)
}

// A clip is attached to a fresh Form for exactly one occurrence. The original Form and its
// fonts remain byte-for-byte reusable by other placements. Cropping is visual, not redaction.
const CLIP: &[u8] = b"LyraReaderClip";
pub(super) fn paints_with_matrices(content: &Content) -> Result<Vec<(usize, PdfMatrix)>> {
    let mut matrix = PdfMatrix::IDENTITY;
    let mut stack = Vec::new();
    let mut paints = Vec::new();
    for (index, op) in content.operations.iter().enumerate() {
        match op.operator.as_str() {
            "q" => stack.push(matrix),
            "Q" => {
                matrix = stack
                    .pop()
                    .ok_or_else(|| failure("Unbalanced graphics state."))?
            }
            "cm" if op.operands.len() == 6 => {
                let v = op
                    .operands
                    .iter()
                    .map(|v| v.as_float().map_err(pdf_error))
                    .collect::<Result<Vec<_>>>()?;
                matrix = PdfMatrix::new(v[0], v[1], v[2], v[3], v[4], v[5]).multiply(matrix);
            }
            "Tj" | "TJ" | "'" | "\"" | "Do" | "sh" | "S" | "s" | "f" | "F" | "f*" | "B" | "B*"
            | "b" | "b*" => paints.push((index, matrix)),
            _ => {}
        }
    }
    Ok(paints)
}

pub(super) fn crop_graphic(
    bytes: &[u8],
    index: u32,
    item: &ContentItem,
    crop: ContentBox,
) -> Result<Vec<u8>> {
    if item.paths.len() != 1 || item.paths[0].len() != 1 {
        return Err(failure("Select the whole graphic to crop it."));
    }
    if !crop.valid()
        || crop.x < 0.0
        || crop.y < 0.0
        || crop.right() > 1.000001
        || crop.top() > 1.000001
    {
        return Err(failure("The crop must lie inside the graphic."));
    }
    let (_, count) = object_info(bytes, index, item.paths[0][0])?;
    let geometry = {
        let pdfium = pdfium_instance()?;
        let _guard = PDFIUM_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let doc = pdfium
            .load_pdf_from_byte_slice(bytes, None)
            .map_err(pdf_error)?;
        let page = doc
            .pages()
            .get(index.try_into().map_err(pdf_error)?)
            .map_err(pdf_error)?;
        crate::backend::page_geometry(&page)
    };
    let view = geometry.page_to_view(1.0).apply_rect(item.bounds.rect());
    let cropped = Rect::new(
        view.min_x() + view.size.width * crop.x,
        view.min_y() + view.size.height * crop.y,
        view.size.width * crop.width,
        view.size.height * crop.height,
    );
    let to_page = geometry
        .view_to_page(1.0)
        .ok_or_else(|| failure("The page transform is singular."))?;
    let mut document = Document::load_mem(bytes).map_err(pdf_error)?;
    let page = document.get_pages()[&(index + 1)];
    let mut content = Content::decode(&document.get_page_content(page)).map_err(pdf_error)?;
    let paints = paints_with_matrices(&content)?;
    if paints.len() != count {
        return Err(failure("The graphic operators cannot be mapped reliably."));
    }
    let (paint, ctm) = paints[item.paths[0][0]];
    if ctm.determinant().abs() < 1e-10 {
        return Err(failure("The graphic transform is singular."));
    }
    let original = content.operations[paint].clone();
    if original.operator != "Do" {
        return Err(failure("The selection is no longer a graphic."));
    }
    let name = original.operands[0].as_name().map_err(pdf_error)?.to_vec();
    let mut resources = page_resources(&document, page)?;
    let mut xobjects =
        resolve_dictionary(&document, resources.get(b"XObject").map_err(pdf_error)?)?;
    let original_id = xobjects.get(&name).map_err(pdf_error)?.clone();
    let inverse = ctm.invert();
    let mut points = Vec::new();
    for (x, y) in [
        (cropped.min_x(), cropped.min_y()),
        (cropped.max_x(), cropped.min_y()),
        (cropped.max_x(), cropped.max_y()),
        (cropped.min_x(), cropped.max_y()),
    ] {
        let point = to_page.apply(lyra_reader_core::Point::new(x, y));
        let (x, y) = inverse.apply_to_points(
            PdfPoints::new(point.x as f32),
            PdfPoints::new(point.y as f32),
        );
        points.push((x.value, y.value));
    }
    let mut operations = vec![Operation::new("q", vec![])];
    for (n, (x, y)) in points.iter().enumerate() {
        operations.push(Operation::new(
            if n == 0 { "m" } else { "l" },
            vec![Object::Real(*x), Object::Real(*y)],
        ));
    }
    operations.extend([
        Operation::new("h", vec![]),
        Operation::new("W", vec![]),
        Operation::new("n", vec![]),
        original,
        Operation::new("Q", vec![]),
    ]);
    let mut dictionary = Dictionary::new();
    dictionary.set("Type", Object::Name(b"XObject".to_vec()));
    dictionary.set("Subtype", Object::Name(b"Form".to_vec()));
    let min_x = points.iter().map(|p| p.0).fold(f32::INFINITY, f32::min);
    let min_y = points.iter().map(|p| p.1).fold(f32::INFINITY, f32::min);
    let max_x = points.iter().map(|p| p.0).fold(f32::NEG_INFINITY, f32::max);
    let max_y = points.iter().map(|p| p.1).fold(f32::NEG_INFINITY, f32::max);
    dictionary.set(
        "BBox",
        Object::Array(vec![min_x.into(), min_y.into(), max_x.into(), max_y.into()]),
    );
    dictionary.set(
        CLIP.to_vec(),
        Object::Array(
            points
                .iter()
                .flat_map(|(x, y)| [Object::Real(*x), Object::Real(*y)])
                .collect(),
        ),
    );
    let mut child_xobjects = Dictionary::new();
    child_xobjects.set(name.to_vec(), original_id);
    let mut child_resources = Dictionary::new();
    child_resources.set("XObject", child_xobjects);
    dictionary.set("Resources", child_resources);
    let wrapper = document.add_object(Stream::new(
        dictionary,
        Content { operations }.encode().map_err(pdf_error)?,
    ));
    let unique = format!("LyraCrop{}", wrapper.0).into_bytes();
    xobjects.set(unique.clone(), wrapper);
    resources.set("XObject", xobjects);
    content.operations[paint].operands[0] = Object::Name(unique);
    let stream = document.add_object(Stream::new(
        Dictionary::new(),
        content.encode().map_err(pdf_error)?,
    ));
    let page = document.get_dictionary_mut(page).map_err(pdf_error)?;
    page.set("Contents", stream);
    page.set("Resources", resources);
    let mut output = Vec::new();
    document.save_to(&mut output).map_err(pdf_error)?;
    Ok(output)
}

/// PDFium's object bounds ignore a Form's clipping path. Limit hit testing to our own known
/// clipping polygon; never infer this from arbitrary third-party Form bounding boxes.
pub(super) fn apply_clips(bytes: &[u8], snapshot: &mut ContentPage) -> Result<()> {
    let document = Document::load_mem(bytes).map_err(pdf_error)?;
    let page = document.get_pages()[&(snapshot.page + 1)];
    let resources = page_resources(&document, page)?;
    let Ok(xobject) = resources.get(b"XObject") else {
        return Ok(());
    };
    let xobjects = resolve_dictionary(&document, xobject)?;
    if !xobjects.iter().any(|(_, o)| {
        document
            .dereference(o)
            .ok()
            .and_then(|(_, o)| o.as_stream().ok())
            .is_some_and(|s| s.dict.has(CLIP))
    }) {
        return Ok(());
    }
    let content = Content::decode(&document.get_page_content(page)).map_err(pdf_error)?;
    for (root, (paint, matrix)) in paints_with_matrices(&content)?.into_iter().enumerate() {
        let op = &content.operations[paint];
        if op.operator != "Do" {
            continue;
        }
        let Some(stream) = op
            .operands
            .first()
            .and_then(|o| o.as_name().ok())
            .and_then(|n| xobjects.get(n).ok())
            .and_then(|o| document.dereference(o).ok())
            .and_then(|(_, o)| o.as_stream().ok())
        else {
            continue;
        };
        let Some(values) = stream
            .dict
            .get(CLIP)
            .ok()
            .and_then(|v| v.as_array().ok())
            .filter(|v| v.len() == 8)
        else {
            continue;
        };
        let values = values
            .iter()
            .map(|v| v.as_float().map_err(pdf_error))
            .collect::<Result<Vec<_>>>()?;
        let points = values
            .as_chunks::<2>()
            .0
            .iter()
            .map(|v| matrix.apply_to_points(PdfPoints::new(v[0]), PdfPoints::new(v[1])))
            .collect::<Vec<_>>();
        let x = points
            .iter()
            .map(|p| p.0.value as f64)
            .fold(f64::INFINITY, f64::min);
        let y = points
            .iter()
            .map(|p| p.1.value as f64)
            .fold(f64::INFINITY, f64::min);
        let right = points
            .iter()
            .map(|p| p.0.value as f64)
            .fold(f64::NEG_INFINITY, f64::max);
        let top = points
            .iter()
            .map(|p| p.1.value as f64)
            .fold(f64::NEG_INFINITY, f64::max);
        snapshot.items.retain_mut(|item| {
            if item.paths.iter().any(|p| p.first() != Some(&root)) {
                return true;
            }
            let left = item.bounds.x.max(x);
            let bottom = item.bounds.y.max(y);
            let width = item.bounds.right().min(right) - left;
            let height = item.bounds.top().min(top) - bottom;
            if width <= 0.0 || height <= 0.0 {
                return false;
            }
            item.bounds = ContentBox {
                x: left,
                y: bottom,
                width,
                height,
            };
            true
        });
    }
    Ok(())
}
