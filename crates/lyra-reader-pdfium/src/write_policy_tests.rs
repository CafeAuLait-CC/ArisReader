//! The public Rust writers must enforce the same policy as the native shell.
use crate::test_support::{ScratchDir, fixture};
use crate::writeback::{OutputMode, SaveMode, save_incremental_with_contract, write_rewritten_pdf};
use lyra_reader_core::ErrorCode;
use std::fs;

#[test]
fn signed_incremental_replacement_is_refused_before_build_or_backup() {
    let scratch = ScratchDir::new("signed-incremental-gate");
    let source = scratch.join("signed.pdf");
    fs::copy(fixture("signed-signature.pdf"), &source).unwrap();
    let before = fs::read(&source).unwrap();
    let error = save_incremental_with_contract(
        &source,
        &source,
        SaveMode::ReplaceOriginal,
        |_| panic!("a signed replacement must be refused before build"),
        |_| Ok(()),
    )
    .unwrap_err();
    assert_eq!(error.code, ErrorCode::ReadOnly);
    assert_eq!(fs::read(&source).unwrap(), before);
    assert_eq!(
        fs::read_dir(&scratch).unwrap().count(),
        1,
        "no backup or temporary"
    );
}

#[test]
fn signed_page_replacement_is_refused_before_build_or_backup() {
    let scratch = ScratchDir::new("signed-rewrite-gate");
    let destination = scratch.join("signed.pdf");
    fs::copy(fixture("signed-docmdp.pdf"), &destination).unwrap();
    let before = fs::read(&destination).unwrap();
    let error = write_rewritten_pdf(
        &fixture("text-page.pdf"),
        &destination,
        OutputMode::ReplaceDestination,
        |_| panic!("a signed replacement must be refused before build"),
        |_| Ok(()),
    )
    .unwrap_err();
    assert_eq!(error.code, ErrorCode::ReadOnly);
    assert_eq!(fs::read(&destination).unwrap(), before);
    assert_eq!(fs::read_dir(&scratch).unwrap().count(), 1);
}

#[test]
fn public_properties_copy_is_signature_free_before_it_is_published() {
    if !crate::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let scratch = ScratchDir::new("signed-properties-copy");
    let source = fixture("signed-signature.pdf");
    let before = fs::read(&source).unwrap();
    let destination = scratch.join("copy.pdf");
    let properties = crate::DocumentProperties {
        title: "Edited title".into(),
        ..Default::default()
    };
    let report =
        crate::save_document_properties(&source, &destination, &properties, None, SaveMode::Copy)
            .unwrap();
    assert!(!crate::detect_signature(&destination, None, 0).is_signed());
    assert!(!report.source_bytes_preserved);
    assert_eq!(report.appended_bytes, 0);
    assert_eq!(
        crate::read_document_info(&destination, None)
            .unwrap()
            .properties
            .title,
        properties.title
    );
    assert_eq!(fs::read(&source).unwrap(), before);
}

fn cyclic_signed_pdf(path: &std::path::Path) {
    use lopdf::{Document, Object, dictionary};
    let mut document = Document::load(fixture("signed-signature.pdf")).unwrap();
    let group = document.add_object(dictionary! { "T" => Object::string_literal("cyclic") });
    document
        .get_object_mut(group)
        .unwrap()
        .as_dict_mut()
        .unwrap()
        .set("Kids", vec![Object::Reference(group)]);
    let form_id = document
        .catalog()
        .unwrap()
        .get(b"AcroForm")
        .unwrap()
        .as_reference()
        .unwrap();
    let form = document
        .get_object_mut(form_id)
        .unwrap()
        .as_dict_mut()
        .unwrap();
    form.get_mut(b"Fields")
        .unwrap()
        .as_array_mut()
        .unwrap()
        .push(Object::Reference(group));
    document.save(path).unwrap();
}

#[test]
fn failed_copy_sanitization_preserves_existing_destination_in_both_transactions() {
    use std::io::Write;
    let scratch = ScratchDir::new("sanitize-failure");
    let source = scratch.join("cyclic.pdf");
    cyclic_signed_pdf(&source);
    let source_bytes = fs::read(&source).unwrap();
    let destination = scratch.join("existing.pdf");
    let prior = b"existing user output must survive";
    for incremental in [true, false] {
        fs::write(&destination, prior).unwrap();
        let build = |file: &mut fs::File| {
            file.write_all(&source_bytes).unwrap();
            Ok(())
        };
        let error = if incremental {
            save_incremental_with_contract(&source, &destination, SaveMode::Copy, build, |_| Ok(()))
                .unwrap_err()
        } else {
            write_rewritten_pdf(&source, &destination, OutputMode::Copy, build, |_| Ok(()))
                .unwrap_err()
        };
        assert_eq!(error.code, ErrorCode::CorruptDocument);
        assert!(error.message.contains("cyclic"));
        assert_eq!(fs::read(&destination).unwrap(), prior);
        assert_eq!(fs::read(&source).unwrap(), source_bytes);
        assert_eq!(
            fs::read_dir(&scratch).unwrap().count(),
            2,
            "no leaked temporaries"
        );
    }
}

#[test]
fn failed_signature_strip_verification_keeps_the_candidate_and_cleans_staging() {
    use lopdf::{Document, dictionary};
    let scratch = ScratchDir::new("strip-verification-failure");
    let copy = scratch.join("copy.pdf");
    let mut document = Document::load(fixture("embedded-file.pdf")).unwrap();
    document
        .catalog_mut()
        .unwrap()
        .set("AcroForm", dictionary! { "SigFlags" => 1 });
    document.save(&copy).unwrap();
    let before = fs::read(&copy).unwrap();
    let error = crate::rewrite::strip_signature_from_copy_with_fault(
        &copy,
        crate::rewrite::RewriteFault::DropEmbeddedFiles,
    )
    .unwrap_err();
    assert!(error.message.contains("embedded files"));
    assert_eq!(fs::read(&copy).unwrap(), before);
    assert_eq!(fs::read_dir(&scratch).unwrap().count(), 1);
}

#[test]
fn indirect_field_and_kids_arrays_still_detect_a_signed_field() {
    use lopdf::{Document, Object, dictionary};
    let scratch = ScratchDir::new("indirect-signature-tree");
    let source = scratch.join("indirect.pdf");
    let mut document = Document::load(fixture("signed-signature.pdf")).unwrap();
    let form_id = document
        .catalog()
        .unwrap()
        .get(b"AcroForm")
        .unwrap()
        .as_reference()
        .unwrap();
    let fields = document
        .get_dictionary(form_id)
        .unwrap()
        .get(b"Fields")
        .unwrap()
        .clone();
    let kids = document.add_object(fields);
    let group = document.add_object(dictionary! { "Kids" => Object::Reference(kids) });
    let fields = document.add_object(vec![Object::Reference(group)]);
    let form = document
        .get_object_mut(form_id)
        .unwrap()
        .as_dict_mut()
        .unwrap();
    form.remove(b"SigFlags");
    form.set("Fields", Object::Reference(fields));
    document.save(&source).unwrap();
    let status = crate::detect_signature(&source, None, 1);
    assert!(
        status
            .evidence
            .iter()
            .any(|e| e.kind == crate::SignatureEvidenceKind::SignatureField)
    );
    let error = save_incremental_with_contract(
        &source,
        &source,
        SaveMode::ReplaceOriginal,
        |_| panic!("must refuse"),
        |_| Ok(()),
    )
    .unwrap_err();
    assert_eq!(error.code, ErrorCode::ReadOnly);
    if crate::is_available() {
        crate::strip_signature_from_copy(&source).unwrap();
        assert!(!crate::detect_signature(&source, None, 0).is_signed());
        let stripped = Document::load(&source).unwrap();
        assert!(
            stripped.catalog().unwrap().get(b"AcroForm").is_ok(),
            "keep non-signature fields"
        );
        assert_eq!(
            crate::read_form_document(&source, None)
                .unwrap()
                .fields
                .len(),
            1
        );
    }
}

#[test]
fn malformed_replacement_is_refused_instead_of_assumed_unsigned() {
    let scratch = ScratchDir::new("malformed-write-gate");
    let source = scratch.join("invalid.pdf");
    fs::write(&source, b"not a PDF").unwrap();
    assert!(
        save_incremental_with_contract(
            &source,
            &source,
            SaveMode::ReplaceOriginal,
            |_| panic!("must refuse unreadable signature structures"),
            |_| Ok(())
        )
        .is_err()
    );
    assert_eq!(fs::read(&source).unwrap(), b"not a PDF");
    assert_eq!(fs::read_dir(&scratch).unwrap().count(), 1);
}

/// CI runs this with LYRA_READER_REQUIRE_PDFIUM=1 so a missing library cannot turn
/// every write-path regression into a successful early return.
#[test]
fn required_pdfium_runtime_is_available() {
    if std::env::var_os("LYRA_READER_REQUIRE_PDFIUM").is_some() {
        assert!(
            crate::is_available(),
            "PDFium is required for the write-path test gate"
        );
    }
}

#[test]
fn a_later_split_failure_leaves_earlier_signed_outputs_signature_free() {
    use lopdf::{Document, Object, dictionary};
    use lyra_reader_core::DocumentBackend;
    if !crate::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let scratch = ScratchDir::new("signed-split-late-failure");
    let source = scratch.join("signed-multipage.pdf");
    let mut document = Document::load(fixture("multipage.pdf")).unwrap();
    let pages = document.get_pages();
    assert!(pages.len() >= 2);
    let mut fields = Vec::new();
    for (index, page) in pages.values().take(2).enumerate() {
        let value = document.add_object(dictionary! {
            "Type" => "Sig", "ByteRange" => vec![0.into(), 1.into(), 2.into(), 3.into()],
            "Contents" => Object::string_literal("obsolete-signature-bytes"),
        });
        let field = document.add_object(dictionary! {
            "Type" => "Annot", "Subtype" => "Widget", "FT" => "Sig",
            "T" => Object::string_literal(format!("signature-{index}")),
            "V" => Object::Reference(value), "P" => Object::Reference(*page),
            "Rect" => vec![10.into(), 10.into(), 50.into(), 30.into()],
        });
        document
            .get_object_mut(*page)
            .unwrap()
            .as_dict_mut()
            .unwrap()
            .set("Annots", vec![Object::Reference(field)]);
        fields.push(Object::Reference(field));
    }
    document.catalog_mut().unwrap().set(
        "AcroForm",
        dictionary! { "SigFlags" => 1, "Fields" => fields },
    );
    document.save(&source).unwrap();
    let before = fs::read(&source).unwrap();
    let first = scratch.join("first.pdf");
    let blocked = scratch.join("blocked.pdf");
    fs::create_dir(&blocked).unwrap();
    let error = crate::split_pages(
        &source,
        &[
            crate::SplitPart {
                destination: first.clone(),
                pages: vec![0],
            },
            crate::SplitPart {
                destination: blocked.clone(),
                pages: vec![1],
            },
        ],
        None,
    )
    .unwrap_err();
    assert!(error.message.contains("1 earlier output"), "{error}");
    let output = crate::PdfiumBackend::open(&first, None).unwrap();
    assert_eq!(output.page_count(), 1);
    assert_eq!(
        output.signature_count(),
        0,
        "each completed part must be sanitized before publish"
    );
    assert!(
        !fs::read(&first)
            .unwrap()
            .windows(b"obsolete-signature-bytes".len())
            .any(|s| s == b"obsolete-signature-bytes")
    );
    assert_eq!(fs::read(&source).unwrap(), before);
    assert!(blocked.is_dir());
    assert_eq!(
        fs::read_dir(&scratch).unwrap().count(),
        3,
        "no leaked temporary"
    );
}

#[test]
fn staged_signed_edits_keep_the_original_guard_but_exports_are_unsigned() {
    if !crate::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let scratch = ScratchDir::new("signed-edit-session");
    let revision = scratch.join("revision.pdf");
    let exported = scratch.join("exported.pdf");
    let operation = crate::PageOperation::InsertBlank { index: 1 };
    crate::stage_page_operation(
        &fixture("signed-signature.pdf"),
        &revision,
        &operation,
        None,
    )
    .unwrap();
    assert!(crate::detect_signature(&revision, None, 0).is_signed());
    crate::publish_edited_copy(&revision, &exported, 2).unwrap();
    assert!(!crate::detect_signature(&exported, None, 0).is_signed());
    let direct_copy = scratch.join("direct-copy.pdf");
    crate::apply_page_operation(
        &fixture("signed-signature.pdf"),
        &direct_copy,
        &operation,
        None,
    )
    .unwrap();
    assert!(!crate::detect_signature(&direct_copy, None, 0).is_signed());
}

#[test]
fn annotation_opens_and_page_writes_share_the_pdfium_transaction_lock() {
    if !crate::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let scratch = ScratchDir::new("concurrent-annotation-writes");
    let source = fixture("multipage.pdf");
    std::thread::scope(|scope| {
        for worker in 0..4 {
            let source = &source;
            let directory = scratch.join(format!("worker-{worker}"));
            fs::create_dir(&directory).unwrap();
            scope.spawn(move || {
                for _ in 0..8 {
                    let reader = crate::AnnotationReader::open(source, None).unwrap();
                    reader.page(lyra_reader_core::PageIndex(0)).unwrap();
                    crate::split_pages(
                        source,
                        &[
                            crate::SplitPart {
                                destination: directory.join("a.pdf"),
                                pages: vec![0],
                            },
                            crate::SplitPart {
                                destination: directory.join("b.pdf"),
                                pages: vec![1],
                            },
                        ],
                        None,
                    )
                    .unwrap();
                    crate::preview_redactions(
                        source,
                        &[crate::RedactionArea::new(
                            0,
                            lyra_reader_core::Rect::new(72.0, 700.0, 100.0, 40.0),
                        )],
                    )
                    .unwrap();
                }
            });
        }
    });
}
