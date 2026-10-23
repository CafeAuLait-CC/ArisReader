//! Read-only XFA coverage against the real sample on this machine.
//!
//! The sample is the user's file under `~/Downloads`; it is copied to a scratch directory and
//! never written in place. When it is absent (CI, another machine) the check returns after a
//! clear SKIP line rather than failing: the committed fixtures cannot include it.
//!
//! Run with:
//!   LYRA_READER_XFA_SAMPLE=~/Downloads/xml_form.pdf cargo test -p lyra-reader-ffi --test xfa_readonly -- --nocapture

use lyra_reader_ffi::{LyraReaderDocument, LyraReaderEngine, LyraReaderFfiError};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn sample_path() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("LYRA_READER_XFA_SAMPLE") {
        let path = PathBuf::from(path);
        return path.is_file().then_some(path);
    }
    let home = std::env::var("HOME").ok()?;
    let path = PathBuf::from(home).join("Downloads/xml_form.pdf");
    path.is_file().then_some(path)
}

fn scratch(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "lyra-reader-xfa-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0)
    ));
    fs::create_dir_all(&path).expect("scratch");
    path
}

fn expect_read_only(label: &str, result: Result<(), LyraReaderFfiError>) {
    match result {
        Err(LyraReaderFfiError::Document { message }) => {
            assert!(
                message.contains("XFA form") && message.contains("read-only"),
                "{label} refused with the wrong sentence: {message}"
            );
        }
        Err(other) => panic!("{label} refused with the wrong error: {other:?}"),
        Ok(()) => panic!("{label} was allowed to write into an XFA document"),
    }
}

fn open(engine: &LyraReaderEngine, path: &Path) -> Arc<LyraReaderDocument> {
    engine
        .open_document(path.to_string_lossy().into_owned(), None)
        .expect("open the XFA form")
}

#[test]
fn xfa_form_is_detected_rendered_five_pages_and_read_only() {
    let Some(sample) = sample_path() else {
        println!("SKIP: ~/Downloads/xml_form.pdf is not present");
        return;
    };
    let scratch = scratch("main");
    let copied = scratch.join("xml_form.pdf");
    fs::copy(&sample, &copied).expect("copy the sample");
    let before = fs::read(&copied).expect("read the copy");
    assert_eq!(
        before,
        fs::read(&sample).expect("read the source"),
        "the copy is byte-identical"
    );

    let engine = LyraReaderEngine::new();
    let document = open(&engine, &copied);
    assert_eq!(document.page_count(), 5, "the printed form has five pages");

    let xfa = document.xfa_status();
    assert!(xfa.is_xfa, "the document is detected as XFA");
    assert!(xfa.rendered, "the synthetic PDF was produced");
    assert_eq!(xfa.page_count, 5);
    assert_eq!(
        xfa.packet_names.len(),
        10,
        "the /XFA array carries ten entries"
    );
    assert!(
        xfa.encrypted,
        "the source is AES-encrypted even though it opened without a prompt"
    );
    assert!(
        !xfa.skipped.is_empty(),
        "the honest fallback list is populated"
    );
    let reason = xfa.read_only_reason.clone().expect("read-only reason");
    assert!(reason.contains("XFA form"));

    // Text from the page's real text layer, including a value resolved through the dataset's
    // LOV table (Country code 511 -> Canada) and a template label.
    let page_text = document.text_page(0).expect("page text").text;
    assert!(
        page_text.contains("APPLICATION TO CHANGE CONDITIONS"),
        "the page text carries the template title: {page_text:.200}"
    );
    assert!(
        page_text.contains("Canada"),
        "the page text carries the dataset-derived country: {page_text:.400}"
    );
    assert!(
        page_text.contains("PAGE 1 OF 5"),
        "the page number is synthesized for the synthetic document"
    );

    // The data itself proves where `Canada` came from.
    let prepared = lyra_reader_xfa::prepare(&copied, None)
        .expect("prepare")
        .expect("XFA");
    assert_eq!(
        prepared.dataset.value_at(&[
            "form1".to_string(),
            "Page1[0]".to_string(),
            "PersonalDetails[0]".to_string(),
            "CurrentCOR[0]".to_string(),
            "CurrentCOR[0]".to_string(),
            "Row2[0]".to_string(),
            "Country[0]".to_string(),
        ]),
        Some("511"),
        "the dataset carries the country code"
    );

    // Form filling is not offered: there are no fields in the synthetic document and the
    // refusal names the read-only policy.
    let form = document.form_info().expect("form info");
    assert!(
        form.fields.is_empty(),
        "an XFA form offers no fillable fields"
    );
    assert!(form.refusal.is_some(), "the form info explains the refusal");
    assert!(document.annotations().expect("annotations").is_empty());

    let info = document.document_info().expect("document info");
    assert_eq!(info.page_count, 5);
    assert!(info.is_encrypted, "the source encryption is reported");

    // Worker copies keep the synthetic pages and the read-only policy.
    let reopened = document.reopen().expect("reopen");
    assert_eq!(reopened.page_count(), 5);
    assert!(reopened.xfa_status().is_xfa);

    // Every representative write command refuses with the shared sentence.
    let destination = scratch.join("out.pdf").to_string_lossy().into_owned();
    let dest = || destination.clone();
    let read_only = |result: Result<(), LyraReaderFfiError>| result;
    expect_read_only(
        "extract_pages",
        read_only(document.extract_pages(dest(), vec![0]).map(|_| ())),
    );
    expect_read_only(
        "merge_documents",
        read_only(document.merge_documents(vec![], dest()).map(|_| ())),
    );
    expect_read_only(
        "save_edited_copy",
        read_only(document.save_edited_copy(dest()).map(|_| ())),
    );
    expect_read_only(
        "replace_with_edited_pages",
        read_only(
            document
                .replace_with_edited_pages(copied.to_string_lossy().into_owned())
                .map(|_| ()),
        ),
    );
    expect_read_only(
        "save_annotations_copy",
        read_only(
            document
                .save_annotations_copy(dest(), vec![], vec![], 1.0)
                .map(|_| ()),
        ),
    );
    expect_read_only(
        "replace_with_annotations",
        read_only(
            document
                .replace_with_annotations(vec![], vec![], 1.0)
                .map(|_| ()),
        ),
    );
    expect_read_only(
        "save_filled_form_copy",
        read_only(document.save_filled_form_copy(dest(), vec![]).map(|_| ())),
    );
    expect_read_only(
        "replace_with_filled_form",
        read_only(document.replace_with_filled_form(vec![]).map(|_| ())),
    );
    expect_read_only(
        "save_document_properties_copy",
        read_only(
            document
                .save_document_properties_copy(
                    dest(),
                    String::new(),
                    String::new(),
                    String::new(),
                    String::new(),
                )
                .map(|_| ()),
        ),
    );
    expect_read_only(
        "replace_with_document_properties",
        read_only(
            document
                .replace_with_document_properties(
                    String::new(),
                    String::new(),
                    String::new(),
                    String::new(),
                )
                .map(|_| ()),
        ),
    );
    expect_read_only(
        "redact_to_copy",
        read_only(document.redact_to_copy(dest(), vec![]).map(|_| ())),
    );
    expect_read_only(
        "replace_with_redactions",
        read_only(document.replace_with_redactions(vec![]).map(|_| ())),
    );
    expect_read_only(
        "apply_content_edit",
        read_only(
            document
                .apply_content_edit(0, "{\"kind\":\"insert_text\"}".to_string(), dest())
                .map(|_| ()),
        ),
    );

    // The source file is byte-identical after every refusal.
    assert_eq!(
        before,
        fs::read(&copied).expect("read the copy after writes"),
        "the source file was modified"
    );

    // The probe sees the synthetic page count too.
    let summary = engine
        .probe_document(copied.to_string_lossy().into_owned(), None)
        .expect("probe");
    assert_eq!(summary.page_count, 5);
    assert!(summary.is_xfa);
    assert!(summary.is_encrypted);
    assert!((summary.first_page_width_pt - 612.0).abs() < 0.1);
    assert!((summary.first_page_height_pt - 792.0).abs() < 0.1);

    let _ = fs::remove_dir_all(&scratch);
}

#[test]
fn ordinary_pdf_is_not_touched_by_xfa_support() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/text-page.pdf");
    let engine = LyraReaderEngine::new();
    let document = engine
        .open_document(fixture.to_string_lossy().into_owned(), None)
        .expect("open the ordinary fixture");
    let xfa = document.xfa_status();
    assert!(!xfa.is_xfa);
    assert!(xfa.read_only_reason.is_none());
    assert_eq!(document.page_count(), 1);
    let info = document.form_info().expect("form info");
    assert!(info.fields.is_empty());
    assert!(
        info.refusal.is_none(),
        "an ordinary PDF is not refused a form"
    );
    let text = document.text_page(0).expect("text page").text;
    assert!(
        !text.is_empty(),
        "the ordinary document's text layer is unchanged"
    );
    let summary = engine
        .probe_document(fixture.to_string_lossy().into_owned(), None)
        .expect("probe");
    assert!(!summary.is_xfa);
}

#[test]
fn a_genuinely_password_protected_pdf_still_refuses_to_open() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/text-page.pdf");
    let scratch = scratch("password");
    let protected = scratch.join("protected.pdf");
    let status = std::process::Command::new("gs")
        .args([
            "-q",
            "-dBATCH",
            "-dNOPAUSE",
            "-sDEVICE=pdfwrite",
            "-dEncryptionR=3",
            "-dKeyLength=128",
            "-dPermissions=-4",
            "-sOwnerPassword=owner-secret",
            "-sUserPassword=user-secret",
            &format!("-sOutputFile={}", protected.display()),
            &fixture.to_string_lossy(),
        ])
        .status();
    let Ok(status) = status else {
        println!(
            "SKIP: Ghostscript is not installed, so no password-protected fixture could be made"
        );
        return;
    };
    if !status.success() || !protected.is_file() {
        println!("SKIP: Ghostscript could not create the password-protected fixture");
        return;
    }
    let engine = LyraReaderEngine::new();
    let result = engine.open_document(protected.to_string_lossy().into_owned(), None);
    match result {
        Err(LyraReaderFfiError::Document { message }) => {
            assert!(
                message.to_ascii_lowercase().contains("password"),
                "the refusal names the password: {message}"
            );
        }
        Err(other) => panic!("wrong refusal for a password-protected PDF: {other:?}"),
        Ok(_) => panic!("a genuinely password-protected PDF opened without a password"),
    }
    let _ = fs::remove_dir_all(&scratch);
}
