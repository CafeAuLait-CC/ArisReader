use lopdf::{Document, Object, Stream, dictionary};
use lyra_reader_pdfium::content_edit::{
    ContentBox, ContentCommand, content_image, edit_content, inspect_content,
};
use std::path::{Path, PathBuf};

fn fixture(name: &str, content: &[u8]) -> PathBuf {
    let directory =
        std::env::temp_dir().join(format!("lyra-content-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let path = directory.join("source.pdf");
    write_pdf(&path, content);
    path
}

fn write_pdf(path: &Path, content: &[u8]) {
    let mut doc = Document::with_version("1.7");
    let pages = doc.new_object_id();
    let font =
        doc.add_object(dictionary! { "Type"=>"Font", "Subtype"=>"Type1", "BaseFont"=>"Helvetica" });
    let stream = doc.add_object(Stream::new(dictionary! {}, content.to_vec()));
    let page = doc.add_object(dictionary! {
        "Type"=>"Page", "Parent"=>pages, "MediaBox"=>vec![0.into(),0.into(),612.into(),792.into()],
        "Resources"=>dictionary! { "Font"=>dictionary! { "F1"=>font } }, "Contents"=>stream
    });
    doc.objects.insert(
        pages,
        Object::Dictionary(dictionary! { "Type"=>"Pages", "Kids"=>vec![page.into()], "Count"=>1 }),
    );
    let catalog = doc.add_object(dictionary! { "Type"=>"Catalog", "Pages"=>pages });
    doc.trailer.set("Root", catalog);
    doc.save(path).unwrap();
}

#[test]
fn kerning_paragraph_replaces_real_content_and_survives_reopen() {
    let source = fixture("replace", b"BT /F1 12 Tf 72 700 Td [(Hello) -120 ( world)] TJ 0 -15 Td (Second line.) Tj ET BT /F1 12 Tf 72 500 Td (Unaffected neighbour) Tj ET");
    let before = std::fs::read(&source).unwrap();
    let page = inspect_content(&source, 0).unwrap();
    let block = page
        .items
        .iter()
        .find(|i| i.text.contains("Hello"))
        .unwrap();
    assert!(block.text.contains("Second"), "{block:?}");
    assert!(block.can_edit_text);
    let destination = source.with_file_name("edited.pdf");
    let mut bounds = block.bounds;
    bounds.height = 42.0;
    bounds.width = 180.0;
    bounds.y -= 20.0;
    edit_content(
        &source,
        &destination,
        0,
        &ContentCommand::ReplaceText {
            revision: page.revision,
            target: block.id.clone(),
            text: "New paragraph.\nSecond line.".into(),
            bounds,
            font: "Original".into(),
            size: 12.0,
            colour: [0, 0, 0, 255],
            alignment: 0,
        },
    )
    .unwrap();
    assert_eq!(std::fs::read(&source).unwrap(), before);
    let reopened = inspect_content(&destination, 0).unwrap();
    let text = reopened
        .items
        .iter()
        .map(|i| i.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    assert!(text.contains("New paragraph"), "{text}");
    assert!(
        !text.contains("Hello"),
        "old text must really be removed: {text}"
    );
    assert!(text.contains("Unaffected neighbour"));
}

#[test]
fn move_then_delete_and_stale_revision_are_transactional() {
    let source = fixture("move", b"BT /F1 12 Tf 72 700 Td (Move this) Tj ET");
    let page = inspect_content(&source, 0).unwrap();
    let block = &page.items[0];
    let destination = source.with_file_name("moved.pdf");
    let bounds = ContentBox {
        x: block.bounds.x + 50.0,
        y: block.bounds.y - 20.0,
        ..block.bounds
    };
    edit_content(
        &source,
        &destination,
        0,
        &ContentCommand::Transform {
            revision: page.revision.clone(),
            target: block.id.clone(),
            bounds,
            rotation: 0.0,
        },
    )
    .unwrap();
    let moved = inspect_content(&destination, 0).unwrap();
    assert!((moved.items[0].bounds.x - bounds.x).abs() < 0.1);
    let output = source.with_file_name("deleted.pdf");
    std::fs::write(&output, b"untouched").unwrap();
    assert!(
        edit_content(
            &destination,
            &output,
            0,
            &ContentCommand::Delete {
                revision: page.revision,
                target: block.id.clone()
            }
        )
        .is_err()
    );
    assert_eq!(std::fs::read(&output).unwrap(), b"untouched");
    std::fs::remove_file(&output).unwrap();
    edit_content(
        &destination,
        &output,
        0,
        &ContentCommand::Delete {
            revision: moved.revision,
            target: moved.items[0].id.clone(),
        },
    )
    .unwrap();
    assert!(inspect_content(&output, 0).unwrap().items.is_empty());
}

#[test]
fn large_horizontal_holes_do_not_join_erased_halves() {
    let source=fixture("hole", b"BT /F1 12 Tf 72 700 Td (Left half) Tj 260 0 Td (Right half) Tj ET BT /F1 12 Tf 72 685 Td (Left next) Tj 260 0 Td (Right next) Tj ET");
    let page = inspect_content(&source, 0).unwrap();
    assert_eq!(page.items.len(), 2, "{:?}", page.items);
    assert!(page.items.iter().all(|i| i.bounds.width < 100.0));
}

#[test]
fn erase_removes_text_and_rebuilds_disjoint_blocks() {
    let source=fixture("erase",b"BT /F1 12 Tf 72 700 Td (Left part SECRET WORDS Right part) Tj 0 -15 Td (Left next SECRET WORDS Right next) Tj ET");
    let snapshot = inspect_content(&source, 0).unwrap();
    let destination = source.with_file_name("erased.pdf");
    let _ = std::fs::remove_file(&destination);
    edit_content(
        &source,
        &destination,
        0,
        &ContentCommand::Redact {
            revision: snapshot.revision,
            bounds: ContentBox {
                x: 119.0,
                y: 680.0,
                width: 98.0,
                height: 33.0,
            },
            blackout: false,
        },
    )
    .unwrap();
    let after = inspect_content(&destination, 0).unwrap();
    assert_eq!(after.items.len(), 2, "{after:?}");
    assert!(
        after
            .items
            .iter()
            .all(|i| i.bounds.width < 95.0 && !i.text.contains("SECRET")),
        "{after:?}"
    );
}

#[test]
fn image_insert_crop_replace_export_preserves_neighbouring_text() {
    let source = fixture("image", b"BT /F1 12 Tf 72 700 Td (Unchanged text) Tj ET");
    let image_path = source.with_file_name("input.png");
    {
        let file = std::fs::File::create(&image_path).unwrap();
        let mut encoder = png::Encoder::new(file, 4, 2);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().unwrap();
        writer
            .write_image_data(&[
                255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255, 255, 0, 0, 255,
                255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
            ])
            .unwrap();
    }
    let page = inspect_content(&source, 0).unwrap();
    let inserted = source.with_file_name("inserted.pdf");
    let _ = std::fs::remove_file(&inserted);
    edit_content(
        &source,
        &inserted,
        0,
        &ContentCommand::InsertImage {
            revision: page.revision,
            bounds: ContentBox {
                x: 72.0,
                y: 500.0,
                width: 100.0,
                height: 50.0,
            },
            image_path: image_path.to_string_lossy().into(),
        },
    )
    .unwrap();
    let page = inspect_content(&inserted, 0).unwrap();
    let image = page.items.iter().find(|i| i.kind == "image").unwrap();
    let png = content_image(&inserted, 0, &image.id, &page.revision).unwrap();
    let mut decoder = png::Decoder::new(std::io::Cursor::new(png))
        .read_info()
        .unwrap();
    assert_eq!(decoder.info().width, 4);
    assert_eq!(decoder.info().height, 2);
    let mut pixels = vec![0; decoder.output_buffer_size().unwrap()];
    decoder.next_frame(&mut pixels).unwrap();
    assert_eq!(&pixels[..4], &[255, 0, 0, 255]);
    let cropped = source.with_file_name("cropped.pdf");
    let _ = std::fs::remove_file(&cropped);
    edit_content(
        &inserted,
        &cropped,
        0,
        &ContentCommand::CropImage {
            revision: page.revision,
            target: image.id.clone(),
            crop: ContentBox {
                x: 0.5,
                y: 0.0,
                width: 0.5,
                height: 1.0,
            },
        },
    )
    .unwrap();
    let page = inspect_content(&cropped, 0).unwrap();
    let image = page.items.iter().find(|i| i.kind == "image").unwrap();
    assert!((image.bounds.x - 122.0).abs() < 0.1);
    assert!((image.bounds.width - 50.0).abs() < 0.1);
    let exported = content_image(&cropped, 0, &image.id, &page.revision).unwrap();
    let mut decoder = png::Decoder::new(std::io::Cursor::new(exported))
        .read_info()
        .unwrap();
    let mut pixels = vec![0; decoder.output_buffer_size().unwrap()];
    decoder.next_frame(&mut pixels).unwrap();
    assert_eq!(decoder.info().width, 2);
    assert_eq!(&pixels[..4], &[0, 0, 255, 255]);
    let replaced = source.with_file_name("replaced.pdf");
    let _ = std::fs::remove_file(&replaced);
    edit_content(
        &cropped,
        &replaced,
        0,
        &ContentCommand::ReplaceImage {
            revision: page.revision,
            target: image.id.clone(),
            image_path: image_path.to_string_lossy().into(),
        },
    )
    .unwrap();
    assert!(
        inspect_content(&replaced, 0)
            .unwrap()
            .items
            .iter()
            .any(|i| i.text.contains("Unchanged text"))
    );
}

#[test]
fn links_create_retarget_move_delete_and_reopen() {
    let source = fixture(
        "link",
        b"BT /F1 12 Tf 72 700 Td (Linked text stays unchanged) Tj ET",
    );
    let snapshot = inspect_content(&source, 0).unwrap();
    let added = source.with_file_name("link-added.pdf");
    let _ = std::fs::remove_file(&added);
    let bounds = ContentBox {
        x: 72.0,
        y: 695.0,
        width: 70.0,
        height: 15.0,
    };
    edit_content(
        &source,
        &added,
        0,
        &ContentCommand::SetLink {
            revision: snapshot.revision,
            target: None,
            bounds,
            page: Some(0),
            uri: None,
        },
    )
    .unwrap();
    let snapshot = inspect_content(&added, 0).unwrap();
    let link = snapshot.items.iter().find(|i| i.kind == "link").unwrap();
    assert_eq!(link.link_page, Some(0));
    assert_eq!(link.text, "to Page 1");
    let changed = source.with_file_name("link-changed.pdf");
    let _ = std::fs::remove_file(&changed);
    edit_content(
        &added,
        &changed,
        0,
        &ContentCommand::SetLink {
            revision: snapshot.revision,
            target: Some(link.id.clone()),
            bounds,
            page: None,
            uri: Some("https://example.org/paper".into()),
        },
    )
    .unwrap();
    let snapshot = inspect_content(&changed, 0).unwrap();
    let link = snapshot.items.iter().find(|i| i.kind == "link").unwrap();
    assert_eq!(link.link_uri.as_deref(), Some("https://example.org/paper"));
    assert_eq!(link.link_page, None);
    let moved = source.with_file_name("link-moved.pdf");
    let _ = std::fs::remove_file(&moved);
    edit_content(
        &changed,
        &moved,
        0,
        &ContentCommand::Transform {
            revision: snapshot.revision,
            target: link.id.clone(),
            bounds: ContentBox { x: 200.0, ..bounds },
            rotation: 0.0,
        },
    )
    .unwrap();
    let snapshot = inspect_content(&moved, 0).unwrap();
    let link = snapshot.items.iter().find(|i| i.kind == "link").unwrap();
    assert_eq!(link.bounds.x, 200.0);
    let deleted = source.with_file_name("link-deleted.pdf");
    let _ = std::fs::remove_file(&deleted);
    edit_content(
        &moved,
        &deleted,
        0,
        &ContentCommand::Delete {
            revision: snapshot.revision,
            target: link.id.clone(),
        },
    )
    .unwrap();
    let after = inspect_content(&deleted, 0).unwrap();
    assert!(after.items.iter().all(|i| i.kind != "link"));
    assert!(
        after
            .items
            .iter()
            .any(|i| i.text == "Linked text stays unchanged")
    );
}

#[test]
fn nested_graphic_label_moves_without_moving_the_other_instance() {
    let source = fixture("form", b"q /Fm Do Q q 1 0 0 1 0 -150 cm /Fm Do Q");
    let mut doc = Document::load(&source).unwrap();
    let page_id = doc.get_pages()[&1];
    let font =
        doc.add_object(dictionary! {"Type"=>"Font","Subtype"=>"Type1","BaseFont"=>"Helvetica"});
    let form=doc.add_object(Stream::new(dictionary! {
        "Type"=>"XObject","Subtype"=>"Form","BBox"=>vec![0.into(),0.into(),612.into(),792.into()],
        "Resources"=>dictionary!{"Font"=>dictionary!{"F1"=>font}}
    },b"BT /F1 12 Tf 72 700 Td (Graphic label) Tj ET".to_vec()));
    doc.get_dictionary_mut(page_id).unwrap().set(
        "Resources",
        dictionary! {"XObject"=>dictionary!{"Fm"=>form}},
    );
    doc.save(&source).unwrap();
    let snapshot = inspect_content(&source, 0).unwrap();
    let labels: Vec<_> = snapshot.items.iter().filter(|i| i.kind == "text").collect();
    assert_eq!(labels.len(), 2, "{snapshot:?}");
    let label = labels[0];
    assert!(!label.can_edit_text);
    let destination = source.with_file_name("moved.pdf");
    let bounds = ContentBox {
        x: label.bounds.x + 50.0,
        ..label.bounds
    };
    edit_content(
        &source,
        &destination,
        0,
        &ContentCommand::Transform {
            revision: snapshot.revision.clone(),
            target: label.id.clone(),
            bounds,
            rotation: 0.0,
        },
    )
    .unwrap();
    let after = inspect_content(&destination, 0).unwrap();
    let moved = after.items.iter().find(|i| i.id == label.id).unwrap();
    assert!((moved.bounds.x - bounds.x).abs() < 0.1, "{after:?}");
    let neighbour = after.items.iter().find(|i| i.id == labels[1].id).unwrap();
    assert!((neighbour.bounds.x - labels[1].bounds.x).abs() < 0.1);
}

#[test]
fn real_manuscript_object_probe() {
    let Ok(samples) = std::env::var("LYRA_READER_PDF_SAMPLES") else {
        return;
    };
    let source = Path::new(&samples).join("manuscript_0925.pdf");
    let mut found = false;
    for page in 0..6 {
        let snapshot = inspect_content(&source, page).unwrap();
        std::fs::write(
            std::env::temp_dir().join(format!("lyra-manuscript-page-{page}.json")),
            serde_json::to_vec_pretty(&snapshot).unwrap(),
        )
        .unwrap();
        if let Some(label) = snapshot
            .items
            .iter()
            .find(|i| i.text.contains("Time-Aware Pose") && i.text.len() < 80)
        {
            eprintln!("real vector label page {page}: {label:?}");
            let output = std::env::temp_dir().join("lyra-manuscript-vector-moved.pdf");
            let _ = std::fs::remove_file(&output);
            let bounds = ContentBox {
                x: label.bounds.x + 8.0,
                ..label.bounds
            };
            edit_content(
                &source,
                &output,
                page,
                &ContentCommand::Transform {
                    revision: snapshot.revision.clone(),
                    target: label.id.clone(),
                    bounds,
                    rotation: 0.0,
                },
            )
            .unwrap();
            let after = inspect_content(&output, page).unwrap();
            let moved = after
                .items
                .iter()
                .find(|i| i.text == label.text && (i.bounds.x - bounds.x).abs() < 0.2);
            assert!(
                moved.is_some(),
                "the label must persist at its new position"
            );
            found = true;
            break;
        }
    }
    assert!(found, "real manuscript vector label was not detected");
}

#[test]
fn real_manuscript_erase_rebuilds_the_surviving_left_paragraph() {
    let Ok(samples) = std::env::var("LYRA_READER_PDF_SAMPLES") else {
        return;
    };
    let source = Path::new(&samples).join("manuscript_0925.pdf");
    let page = inspect_content(&source, 6).unwrap();
    let block = page
        .items
        .iter()
        .find(|i| i.text.starts_with("As shown in Table"))
        .expect("page 7 quantitative results paragraph");
    let area = ContentBox {
        x: block.bounds.x + block.bounds.width * 0.4,
        y: block.bounds.y - 1.0,
        width: block.bounds.width * 0.3,
        height: block.bounds.height + 2.0,
    };
    let output = std::env::temp_dir().join("lyra-manuscript-erased.pdf");
    let _ = std::fs::remove_file(&output);
    edit_content(
        &source,
        &output,
        6,
        &ContentCommand::Redact {
            revision: page.revision,
            bounds: area,
            blackout: false,
        },
    )
    .unwrap();
    let after = inspect_content(&output, 6).unwrap();
    let left = after
        .items
        .iter()
        .find(|i| i.text.starts_with("As shown in Table"))
        .expect("surviving left paragraph");
    assert!(left.bounds.width < block.bounds.width * 0.45, "{left:?}");
    assert!(
        after.items.iter().any(|i| i.text.starts_with("Table 1:")),
        "table caption must remain editable text"
    );
}
