//! Recover explicitly isolated graphics groups in flat page streams. Only complete q/Q
//! scopes whose paint operators map one-to-one to PDFium objects are editable as figures.
use super::*;
use lopdf::content::{Content, Operation};
use lopdf::{Dictionary, Document, Object, Stream};

fn scopes(content: &Content) -> Result<Vec<(usize, usize, Vec<usize>)>> {
    let paints = nested::paints_with_matrices(content)?;
    let mut stack = Vec::new();
    let mut out = Vec::new();
    for (i, op) in content.operations.iter().enumerate() {
        match op.operator.as_str() {
            "q" => stack.push(i),
            "Q" => {
                let start = stack
                    .pop()
                    .ok_or_else(|| failure("Unbalanced graphic group."))?;
                let members = paints
                    .iter()
                    .enumerate()
                    .filter(|(_, p)| p.0 > start && p.0 < i)
                    .map(|(n, _)| n)
                    .collect();
                out.push((start, i, members));
            }
            _ => {}
        }
    }
    Ok(out)
}
fn group_id(first: usize, last: usize) -> String {
    format!("group:{first}:{last}")
}

pub(super) fn append(bytes: &[u8], snapshot: &mut ContentPage) -> Result<()> {
    let document = Document::load_mem(bytes).map_err(pdf_error)?;
    let page_id = document.get_pages()[&(snapshot.page + 1)];
    let content = Content::decode(&document.get_page_content(page_id)).map_err(pdf_error)?;
    let paints = nested::paints_with_matrices(&content)?;
    let pdfium = pdfium_instance()?;
    let _guard = PDFIUM_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let doc = pdfium
        .load_pdf_from_byte_slice(bytes, None)
        .map_err(pdf_error)?;
    let page = doc
        .pages()
        .get(snapshot.page.try_into().map_err(pdf_error)?)
        .map_err(pdf_error)?;
    if paints.len() != page.objects().len() {
        return Ok(());
    }
    let mut used = std::collections::HashSet::new();
    for (start, end, members) in scopes(&content)? {
        if members.len() < 8 || members.iter().any(|n| used.contains(n)) {
            continue;
        }
        let shapes = members
            .iter()
            .filter(|n| {
                !matches!(
                    content.operations[paints[**n].0].operator.as_str(),
                    "Tj" | "TJ" | "'" | "\""
                )
            })
            .count();
        if shapes < 4 || shapes * 2 < members.len() {
            continue;
        }
        let mut bounds: Option<ContentBox> = None;
        for n in &members {
            let b = object_box(
                &page.objects().get(*n).map_err(pdf_error)?,
                PdfMatrix::IDENTITY,
            )?;
            if b.width > 0.0 || b.height > 0.0 {
                bounds = Some(bounds.map_or(b, |a| a.union(b)));
            }
        }
        let Some(bounds) = bounds else { continue };
        let geometry = crate::backend::page_geometry(&page);
        if !bounds.valid()
            || bounds.width < 60.0
            || bounds.height < 40.0
            || bounds.width * bounds.height
                > geometry.crop_box.size.width * geometry.crop_box.size.height * 0.8
        {
            continue;
        }
        used.extend(members.iter().copied());
        snapshot.items.push(ContentItem {
            id: group_id(start, end),
            kind: "graphic".into(),
            bounds,
            text: String::new(),
            font: String::new(),
            size: 12.,
            colour: [0, 0, 0, 255],
            can_edit_text: false,
            reason: None,
            paths: members.into_iter().map(|n| vec![n]).collect(),
            baseline: 0.,
            link_page: None,
            link_uri: None,
        });
    }
    Ok(())
}

pub(super) fn materialize(
    bytes: &[u8],
    index: u32,
    item: &ContentItem,
) -> Result<(Vec<u8>, ContentItem)> {
    let mut document = Document::load_mem(bytes).map_err(pdf_error)?;
    let page_id = document.get_pages()[&(index + 1)];
    let mut content = Content::decode(&document.get_page_content(page_id)).map_err(pdf_error)?;
    let (start, end, members) = scopes(&content)?
        .into_iter()
        .find(|(a, b, m)| {
            group_id(*a, *b) == item.id
                && m.iter().map(|n| vec![*n]).collect::<Vec<_>>() == item.paths
        })
        .ok_or_else(|| failure("The graphic group changed."))?;
    let resources = nested::page_resources(&document, page_id)?;
    let mut dictionary = Dictionary::new();
    dictionary.set("Type", Object::Name(b"XObject".to_vec()));
    dictionary.set("Subtype", Object::Name(b"Form".to_vec()));
    let mut prefix = Content {
        operations: content.operations[..start].to_vec(),
    };
    prefix.operations.push(Operation::new("Do", vec![]));
    let ctm = nested::paints_with_matrices(&prefix)?.last().unwrap().1;
    if ctm.determinant().abs() < 1e-10 {
        return Err(failure("The graphic group transform is singular."));
    }
    let local = object_rect_in_matrix(item.bounds, ctm.invert());
    dictionary.set(
        "BBox",
        vec![
            Object::Real((local.x - 4.) as f32),
            Object::Real((local.y - 4.) as f32),
            Object::Real((local.right() + 4.) as f32),
            Object::Real((local.top() + 4.) as f32),
        ],
    );
    dictionary.set("Resources", resources.clone());
    let form = document.add_object(Stream::new(
        dictionary,
        Content {
            operations: content.operations[start..=end].to_vec(),
        }
        .encode()
        .map_err(pdf_error)?,
    ));
    let name = format!("LyraGroup{}", form.0).into_bytes();
    let mut resources = resources;
    let mut xobjects = resources
        .get(b"XObject")
        .ok()
        .and_then(|o| document.dereference(o).ok())
        .and_then(|(_, o)| o.as_dict().ok())
        .cloned()
        .unwrap_or_default();
    xobjects.set(name.clone(), form);
    resources.set("XObject", xobjects);
    content.operations.splice(
        start..=end,
        [Operation::new("Do", vec![Object::Name(name)])],
    );
    let stream = document.add_object(Stream::new(
        Dictionary::new(),
        content.encode().map_err(pdf_error)?,
    ));
    let page = document.get_dictionary_mut(page_id).map_err(pdf_error)?;
    page.set("Contents", stream);
    page.set("Resources", resources);
    let mut output = Vec::new();
    document.save_to(&mut output).map_err(pdf_error)?;
    let mut item = item.clone();
    item.id = members[0].to_string();
    item.paths = vec![vec![members[0]]];
    Ok((output, item))
}

fn object_rect_in_matrix(bounds: ContentBox, matrix: PdfMatrix) -> ContentBox {
    let t = Transform2D::new(
        matrix.a() as f64,
        matrix.b() as f64,
        matrix.c() as f64,
        matrix.d() as f64,
        matrix.e() as f64,
        matrix.f() as f64,
    );
    t.apply_rect(bounds.rect()).into()
}
