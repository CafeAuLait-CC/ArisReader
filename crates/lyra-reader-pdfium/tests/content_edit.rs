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
fn text_frame_grows_for_wrapping_and_retains_its_top_and_width() {
    let source = fixture("grow", b"BT /F1 12 Tf 72 700 Td (Short text.) Tj ET BT /F1 12 Tf 72 650 Td (Untouched neighbour) Tj ET");
    let page = inspect_content(&source, 0).unwrap();
    let item = page.items.iter().find(|i| i.text == "Short text.").unwrap();
    let text =
        "A longer paragraph with inserted words, a replacement and a second line.\nMore text.";
    let output = source.with_file_name("grown.pdf");
    edit_content(
        &source,
        &output,
        0,
        &ContentCommand::ReplaceText {
            revision: page.revision,
            target: item.id.clone(),
            text: text.into(),
            bounds: item.bounds,
            font: "Helvetica".into(),
            size: item.size,
            colour: item.colour,
            alignment: 0,
        },
    )
    .unwrap();
    let after = inspect_content(&output, 0).unwrap();
    let grown = after
        .items
        .iter()
        .find(|i| i.text.starts_with("A longer"))
        .unwrap();
    assert!(grown.bounds.height > item.bounds.height * 2.0);
    assert!((grown.bounds.width - item.bounds.width).abs() < 0.1);
    assert!(
        (grown.bounds.y + grown.bounds.height - item.bounds.y - item.bounds.height).abs() < 0.1
    );
    assert!(after.items.iter().any(|i| i.text == "Untouched neighbour"));
    // The longer frame now overlaps its neighbour. It must remain one independently
    // selectable/editable block across several revisions, without absorbing that neighbour.
    let second = source.with_file_name("edited-again.pdf");
    edit_content(
        &output,
        &second,
        0,
        &ContentCommand::ReplaceText {
            revision: after.revision.clone(),
            target: grown.id.clone(),
            text: "Edited again.".into(),
            bounds: grown.bounds,
            font: "Original".into(),
            size: grown.size,
            colour: grown.colour,
            alignment: 0,
        },
    )
    .unwrap();
    let reopened = inspect_content(&second, 0).unwrap();
    assert!(
        reopened
            .items
            .iter()
            .any(|i| i.text.replace('\n', " ") == "Edited again.")
    );
    assert!(
        reopened
            .items
            .iter()
            .any(|i| i.text == "Untouched neighbour")
    );
}

#[test]
fn real_review_paragraphs_accept_insert_delete_replace_and_longer_text() {
    let Ok(samples) = std::env::var("LYRA_READER_PDF_SAMPLES") else {
        return;
    };
    for name in [
        "review_ashley_0826.pdf",
        "review_du_0923.pdf",
        "manuscript_0925.pdf",
    ] {
        let source = Path::new(&samples).join(name);
        if !source.exists() {
            continue;
        }
        let page = inspect_content(&source, 0).unwrap();
        let item = page
            .items
            .iter()
            .find(|i| {
                i.can_edit_text
                    && i.bounds.width > 150.0
                    && i.text.chars().filter(|c| c.is_alphabetic()).count() > 100
            })
            .expect("a real body paragraph");
        let original = item.text.replace('\n', " ");
        let variants = [
            format!("{original} More text."),
            original.chars().skip(4).collect(),
            original.replacen(' ', " edited ", 1),
            format!(
                "{original}\nAdditional text for a longer paragraph that wraps onto another line."
            ),
        ];
        for (index, text) in variants.iter().enumerate() {
            let output = std::env::temp_dir().join(format!("lyra-feedback-{name}-{index}.pdf"));
            let _ = std::fs::remove_file(&output);
            edit_content(
                &source,
                &output,
                0,
                &ContentCommand::ReplaceText {
                    revision: page.revision.clone(),
                    target: item.id.clone(),
                    text: text.clone(),
                    bounds: item.bounds,
                    font: "Original".into(),
                    size: item.size,
                    colour: item.colour,
                    alignment: 0,
                },
            )
            .unwrap_or_else(|e| panic!("{name} variant {index}: {e}"));
        }
    }
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

#[test]
fn rotated_cropped_pages_insert_upright_text_and_keep_the_frame_on_reedit() {
    use lyra_reader_core::{PageGeometry, Rect, Rotation};
    for (rotation, value) in [
        (Rotation::None, 0),
        (Rotation::Clockwise90, 90),
        (Rotation::Clockwise180, 180),
        (Rotation::Clockwise270, 270),
    ] {
        let source = fixture(
            &format!("rotate-{value}"),
            b"BT /F1 12 Tf 300 500 Td (Neighbour) Tj ET",
        );
        let mut document = Document::load(&source).unwrap();
        let page_id = document.get_pages()[&1];
        let dictionary = document.get_dictionary_mut(page_id).unwrap();
        dictionary.set("Rotate", value);
        dictionary.set(
            "CropBox",
            vec![20.into(), 30.into(), 592.into(), 762.into()],
        );
        document.save(&source).unwrap();
        let geometry = PageGeometry::new(
            Rect::new(0., 0., 612., 792.),
            Rect::new(20., 30., 572., 732.),
            rotation,
            1.,
        );
        let frame = Rect::new(40., 40., 180., 50.);
        let r = geometry.view_to_page(1.).unwrap().apply_rect(frame);
        let bounds = ContentBox {
            x: r.origin.x,
            y: r.origin.y,
            width: r.size.width,
            height: r.size.height,
        };
        let first = source.with_file_name("inserted.pdf");
        let _ = std::fs::remove_file(&first);
        eprintln!("rotation {value}");
        edit_content(
            &source,
            &first,
            0,
            &ContentCommand::InsertText {
                revision: inspect_content(&source, 0).unwrap().revision,
                text: "Short".into(),
                bounds,
                font: "Helvetica".into(),
                size: 12.,
                colour: [0, 0, 0, 255],
                alignment: 0,
            },
        )
        .unwrap();
        let snapshot = inspect_content(&first, 0).unwrap();
        let item = snapshot
            .items
            .iter()
            .find(|i| i.text == "Short")
            .expect("inserted text");
        assert!(item.can_edit_text, "rotation {value}: {item:?}");
        assert!(
            (item.bounds.width - bounds.width).abs() < 0.01,
            "the text frame must survive reopening"
        );
        let second = source.with_file_name("replaced.pdf");
        let _ = std::fs::remove_file(&second);
        edit_content(
            &first,
            &second,
            0,
            &ContentCommand::ReplaceText {
                revision: snapshot.revision,
                target: item.id.clone(),
                text: "A longer replacement\nSecond line".into(),
                bounds: item.bounds,
                font: "Original".into(),
                size: 12.,
                colour: [0, 0, 0, 255],
                alignment: 0,
            },
        )
        .unwrap();
        let replaced = inspect_content(&second, 0).unwrap();
        let paragraph = replaced
            .items
            .iter()
            .find(|i| i.text.contains("replacement"))
            .unwrap();
        assert!(
            paragraph.text.contains("Second line"),
            "view-space rows must form one paragraph: {paragraph:?}"
        );
        assert!(
            (geometry
                .page_to_view(1.)
                .apply_rect(Rect::new(
                    paragraph.bounds.x,
                    paragraph.bounds.y,
                    paragraph.bounds.width,
                    paragraph.bounds.height
                ))
                .size
                .width
                - 180.)
                .abs()
                < 0.1
        );
    }
}

#[test]
fn vector_crop_is_scoped_to_one_form_and_survives_move_and_reopen() {
    let source = fixture("form-crop", b"q /Fm Do Q q 1 0 0 1 0 -150 cm /Fm Do Q");
    let mut document = Document::load(&source).unwrap();
    let page = document.get_pages()[&1];
    let font = document
        .add_object(dictionary! {"Type"=>"Font","Subtype"=>"Type1","BaseFont"=>"Helvetica"});
    let form=document.add_object(Stream::new(dictionary!{"Type"=>"XObject","Subtype"=>"Form","BBox"=>vec![60.into(),600.into(),300.into(),720.into()],"Resources"=>dictionary!{"Font"=>dictionary!{"F1"=>font}}},b"0 0.4 0 rg 60 600 240 120 re f BT /F1 12 Tf 72 700 Td (Vector label) Tj ET".to_vec()));
    document.get_dictionary_mut(page).unwrap().set(
        "Resources",
        dictionary! {"XObject"=>dictionary!{"Fm"=>form}},
    );
    document.save(&source).unwrap();
    let snapshot = inspect_content(&source, 0).unwrap();
    let item = snapshot
        .items
        .iter()
        .find(|i| i.kind == "graphic" && i.paths == vec![vec![0]])
        .unwrap();
    let cropped = source.with_file_name("cropped.pdf");
    let _ = std::fs::remove_file(&cropped);
    edit_content(
        &source,
        &cropped,
        0,
        &ContentCommand::CropImage {
            revision: snapshot.revision,
            target: item.id.clone(),
            crop: ContentBox {
                x: 0.,
                y: 0.,
                width: 0.5,
                height: 1.,
            },
        },
    )
    .unwrap();
    let after = inspect_content(&cropped, 0).unwrap();
    let visible = after
        .items
        .iter()
        .find(|i| i.kind == "graphic" && i.paths == vec![vec![0]])
        .unwrap();
    assert!(
        (visible.bounds.width - item.bounds.width * 0.5).abs() < 0.1,
        "{after:?}"
    );
    let other = after
        .items
        .iter()
        .find(|i| i.kind == "graphic" && i.paths == vec![vec![1]])
        .unwrap();
    assert!(
        (other.bounds.width - item.bounds.width).abs() < 0.1,
        "shared form occurrence must remain whole"
    );
    let moved = source.with_file_name("moved.pdf");
    let _ = std::fs::remove_file(&moved);
    let bounds = ContentBox {
        x: visible.bounds.x + 10.,
        ..visible.bounds
    };
    edit_content(
        &cropped,
        &moved,
        0,
        &ContentCommand::Transform {
            revision: after.revision,
            target: visible.id.clone(),
            bounds,
            rotation: 0.,
        },
    )
    .unwrap();
    let reopened = inspect_content(&moved, 0).unwrap();
    let moved = reopened
        .items
        .iter()
        .find(|i| i.kind == "graphic" && i.paths == vec![vec![0]])
        .unwrap();
    assert!(
        (moved.bounds.x - bounds.x).abs() < 0.1 && (moved.bounds.width - bounds.width).abs() < 0.1,
        "{moved:?}"
    );
}

#[test]
fn real_manuscript_chart_can_be_cropped_without_rasterizing_the_page() {
    let Ok(samples) = std::env::var("LYRA_READER_PDF_SAMPLES") else {
        return;
    };
    let source = Path::new(&samples).join("manuscript_0925.pdf");
    let page = (7..10)
        .map(|n| inspect_content(&source, n).unwrap())
        .find(|p| {
            p.items.iter().any(|i| {
                (i.kind == "graphic" || i.kind == "image")
                    && i.paths[0].len() == 1
                    && i.bounds.width > 100.
                    && i.bounds.height > 80.
            })
        })
        .expect("manuscript chart page");
    let chart = page
        .items
        .iter()
        .filter(|i| {
            (i.kind == "graphic" || i.kind == "image")
                && i.paths[0].len() == 1
                && i.bounds.width > 100.
                && i.bounds.height > 80.
        })
        .max_by(|a, b| a.bounds.x.total_cmp(&b.bounds.x))
        .expect("chart on manuscript page 8");
    let output = std::env::temp_dir().join("lyra-manuscript-chart-cropped.pdf");
    let _ = std::fs::remove_file(&output);
    edit_content(
        &source,
        &output,
        page.page,
        &ContentCommand::CropImage {
            revision: page.revision,
            target: chart.id.clone(),
            crop: ContentBox {
                x: 0.1,
                y: 0.1,
                width: 0.8,
                height: 0.8,
            },
        },
    )
    .unwrap();
    let reopened = inspect_content(&output, page.page).unwrap();
    let cropped = reopened
        .items
        .iter()
        .find(|i| i.kind == chart.kind && (i.bounds.width - chart.bounds.width * 0.8).abs() < 0.1)
        .unwrap();
    assert!(
        (cropped.bounds.width - chart.bounds.width * 0.8).abs() < 0.1,
        "{cropped:?}"
    );
    assert!(
        reopened
            .items
            .iter()
            .any(|i| i.text.contains("Robustness to Sparse"))
    );
}

#[test]
fn flat_vector_figure_can_be_selected_cropped_and_moved() {
    let mut content =
        b"BT /F1 12 Tf 72 700 Td (Neighbour) Tj ET q 1 0 0 1 50 400 cm 0 0.4 0 rg ".to_vec();
    for n in 0..8 {
        content.extend_from_slice(format!("{} 0 10 100 re f ", n * 20).as_bytes());
    }
    content.extend_from_slice(b"BT /F1 12 Tf 0 110 Td (Flat vector label) Tj ET Q");
    let source = fixture("flat-vector", &content);
    let snapshot = inspect_content(&source, 0).unwrap();
    let group = snapshot
        .items
        .iter()
        .find(|i| i.id.starts_with("group:"))
        .expect("isolated flat figure");
    let output = source.with_file_name("cropped.pdf");
    let _ = std::fs::remove_file(&output);
    edit_content(
        &source,
        &output,
        0,
        &ContentCommand::CropImage {
            revision: snapshot.revision,
            target: group.id.clone(),
            crop: ContentBox {
                x: 0.1,
                y: 0.,
                width: 0.8,
                height: 1.,
            },
        },
    )
    .unwrap();
    let after = inspect_content(&output, 0).unwrap();
    let graphic = after
        .items
        .iter()
        .find(|i| i.kind == "graphic" && i.paths[0].len() == 1)
        .unwrap();
    assert!(
        (graphic.bounds.width - group.bounds.width * 0.8).abs() < 0.1,
        "{graphic:?}"
    );
    let moved = source.with_file_name("moved.pdf");
    let _ = std::fs::remove_file(&moved);
    edit_content(
        &output,
        &moved,
        0,
        &ContentCommand::Transform {
            revision: after.revision,
            target: graphic.id.clone(),
            bounds: ContentBox {
                x: graphic.bounds.x + 12.,
                ..graphic.bounds
            },
            rotation: 0.,
        },
    )
    .unwrap();
    let after = inspect_content(&moved, 0).unwrap();
    assert!(
        after
            .items
            .iter()
            .any(|i| i.kind == "graphic" && (i.bounds.x - graphic.bounds.x - 12.).abs() < 0.1)
    );
}

#[test]
fn real_manuscript_simple_body_replaces_with_original_embedded_font() {
    let Ok(samples) = std::env::var("LYRA_READER_PDF_SAMPLES") else {
        return;
    };
    let source = Path::new(&samples).join("manuscript_0925.pdf");
    let page = inspect_content(&source, 1).unwrap();
    let item = page
        .items
        .iter()
        .find(|i| i.text.starts_with("In this work, we consider") && i.can_edit_text)
        .expect("simple manuscript paragraph");
    let text = "In this work, we consider a direct visual motion demonstration.";
    let output = std::env::temp_dir().join("lyra-manuscript-body-edited.pdf");
    let _ = std::fs::remove_file(&output);
    edit_content(
        &source,
        &output,
        1,
        &ContentCommand::ReplaceText {
            revision: page.revision,
            target: item.id.clone(),
            text: text.into(),
            bounds: item.bounds,
            font: "Original".into(),
            size: item.size,
            colour: item.colour,
            alignment: 0,
        },
    )
    .unwrap();
    let page = inspect_content(&output, 1).unwrap();
    assert!(
        page.items
            .iter()
            .any(|i| i.text == text && (i.bounds.width - item.bounds.width).abs() < 0.1)
    );
}

#[test]
fn chinese_editor_font_and_unsupported_glyph_failures_are_transactional() {
    let source = fixture("cjk", b"BT /F1 12 Tf 72 700 Td (Neighbour) Tj ET");
    let page = inspect_content(&source, 0).unwrap();
    let bounds = ContentBox {
        x: 72.,
        y: 500.,
        width: 200.,
        height: 50.,
    };
    let output = source.with_file_name("chinese.pdf");
    let _ = std::fs::remove_file(&output);
    edit_content(
        &source,
        &output,
        0,
        &ContentCommand::InsertText {
            revision: page.revision.clone(),
            text: "编辑 PDF 正文".into(),
            bounds,
            font: "LyraReader Sans SC".into(),
            size: 14.,
            colour: [0, 0, 0, 255],
            alignment: 0,
        },
    )
    .unwrap();
    let after = inspect_content(&output, 0).unwrap();
    assert!(
        after
            .items
            .iter()
            .any(|i| i.text.replace('\u{a0}', " ") == "编辑 PDF 正文"),
        "{after:?}"
    );
    let blocked = source.with_file_name("blocked.pdf");
    std::fs::write(&blocked, b"preserved").unwrap();
    assert!(
        edit_content(
            &source,
            &blocked,
            0,
            &ContentCommand::InsertText {
                revision: page.revision,
                text: "🦊".into(),
                bounds,
                font: "LyraReader Sans SC".into(),
                size: 14.,
                colour: [0, 0, 0, 255],
                alignment: 0
            }
        )
        .is_err()
    );
    assert_eq!(std::fs::read(blocked).unwrap(), b"preserved");
}

#[test]
fn erase_tj_after_another_show_keeps_operator_local_character_indices() {
    let source=fixture("tj-erase",b"BT /F1 12 Tf 72 700 Td (Neighbour) Tj 0 -30 Td [(Left ) -120 (SECRET) -120 ( Right)] TJ ET");
    let snapshot = inspect_content(&source, 0).unwrap();
    let output = source.with_file_name("erased.pdf");
    let _ = std::fs::remove_file(&output);
    edit_content(
        &source,
        &output,
        0,
        &ContentCommand::Redact {
            revision: snapshot.revision,
            bounds: ContentBox {
                x: 93.,
                y: 660.,
                width: 54.,
                height: 23.,
            },
            blackout: true,
        },
    )
    .unwrap();
    let page = inspect_content(&output, 0).unwrap();
    let text = page
        .items
        .iter()
        .map(|i| i.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    assert!(
        !text.contains("SECRET")
            && text.contains("Neighbour")
            && text.contains("Left")
            && text.contains("Right"),
        "{text}"
    );
}
