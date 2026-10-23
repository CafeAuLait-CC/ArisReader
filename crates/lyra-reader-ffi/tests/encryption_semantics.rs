//! The reporting change (`is_encrypted` means "carries /Encrypt") must not change how an
//! ordinary, non-XFA PDF encrypted with an empty user password opens or refuses a write.
//!
//! `form-fields-encrypted.pdf` is RC4-encrypted with an empty user password and no owner prompt:
//! it opens with no password, reports encrypted, and a write must still reach the old
//! encrypted-document refusal rather than a generic or new one.

use lyra_reader_ffi::{LyraReaderEngine, LyraReaderFfiError};
use std::fs;
use std::path::{Path, PathBuf};

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/form-fields-encrypted.pdf")
}

fn scratch() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "lyra-reader-encrypted-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0)
    ));
    fs::create_dir_all(&path).expect("scratch");
    path
}

fn assert_encrypted_refusal(label: &str, error: LyraReaderFfiError) {
    let message = match error {
        LyraReaderFfiError::Document { message } => message,
        other => panic!("{label} gave a non-document error: {other:?}"),
    };
    let lower = message.to_ascii_lowercase();
    assert!(
        lower.contains("encrypted") || lower.contains("password"),
        "{label} must name the encryption, got: {message}"
    );
    assert!(
        !lower.contains("corrupt") && !lower.contains("not an xfa"),
        "{label} must not look like a parse/XFA error, got: {message}"
    );
    println!("{label} refused with: {message}");
}

#[test]
fn empty_password_encrypted_pdf_opens_without_a_prompt_and_keeps_its_write_refusal() {
    let file = fixture();
    assert!(file.is_file(), "the committed encrypted fixture is missing");
    let before = fs::read(&file).expect("read fixture");
    let scratch = scratch();
    let engine = LyraReaderEngine::new();

    // 1. It opens with no password prompt.
    let document = engine
        .open_document(file.to_string_lossy().into_owned(), None)
        .expect("an empty-user-password encrypted PDF opens without a prompt");
    assert_eq!(document.page_count(), 2);
    assert!(
        !document.xfa_status().is_xfa,
        "the fixture is an ordinary AcroForm PDF"
    );
    let info = document.document_info().expect("document info");
    assert!(info.is_encrypted, "the encrypted dictionary is reported");
    let summary = engine
        .probe_document(file.to_string_lossy().into_owned(), None)
        .expect("probe opens without a prompt");
    assert!(summary.is_encrypted, "probe reports the encryption");
    assert!(!summary.is_xfa);

    // 2. A write still reaches the encrypted-document refusal it had before the reporting
    //    change (the gate uses "a password was supplied", not "the file has /Encrypt").
    let destination = scratch.join("out.pdf");
    match document.save_document_properties_copy(
        destination.to_string_lossy().into_owned(),
        "Encrypted fixture".to_string(),
        String::new(),
        String::new(),
        String::new(),
    ) {
        Ok(_) => panic!("saving properties into an encrypted PDF was allowed"),
        Err(error) => assert_encrypted_refusal("save_document_properties_copy", error),
    }
    match document.extract_pages(destination.to_string_lossy().into_owned(), vec![0]) {
        Ok(_) => panic!("extracting pages from an encrypted PDF was allowed"),
        Err(error) => assert_encrypted_refusal("extract_pages", error),
    }

    // 3. The refusal did not touch the file.
    assert_eq!(
        before,
        fs::read(&file).expect("read fixture after refusals")
    );
    let _ = fs::remove_dir_all(&scratch);
}
