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
fn page_resources(doc: &Document, mut page: ObjectId) -> Result<Dictionary> {
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
