//! Writes the four text boxes the CJK appearance change is evidenced with.
//!
//! Run with PDFium available:
//!
//! ```text
//! LYRA_READER_PDFIUM_PATH=vendor/pdfium/lib/libpdfium.dylib \
//! cargo run -p lyra-reader-pdfium --example cjk_appearance_evidence -- \
//!     tests/fixtures/source.pdf /tmp/lyra-reader-cjk-evidence.pdf
//! ```
//!
//! The source is never modified: [`save_annotated_pdf`] writes a copy. Render the output with
//! PDFKit, Poppler and Ghostscript; the four boxes show Chinese, Japanese, a Greek/maths run and
//! an emoji/rare-character fallback. The `/Contents` strings and the appearance's `/ToUnicode`
//! text are the same exact input strings.

use lyra_reader_core::DocumentBackend;
use lyra_reader_core::{AnnotationAlignment, PageIndex, Rect};
use lyra_reader_pdfium::{
    PdfiumBackend, SaveMode, WriteAnnotation, WriteAnnotationKind, save_annotated_pdf,
};
use std::path::PathBuf;

const IDS: [&str; 4] = [
    "cjk-evidence-chinese",
    "cjk-evidence-japanese",
    "cjk-evidence-greek-maths",
    "cjk-evidence-emoji-rare",
];

const TEXTS: [&str; 4] = [
    "中文测试：这是一条中文批注。",
    "日本語のテキストです。語と観。",
    "α ≤ ∑ ∈ √ ∞ ∂ ∇ ≠ ≈ ⊂ ⊆",
    "Emoji 😀 and rare 龘.",
];

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let source = PathBuf::from(
        arguments
            .next()
            .ok_or("usage: cjk_appearance_evidence <fixture.pdf> <output.pdf>")?,
    );
    let destination = PathBuf::from(
        arguments
            .next()
            .ok_or("usage: cjk_appearance_evidence <fixture.pdf> <output.pdf>")?,
    );

    let backend = PdfiumBackend::open(&source, None)?;
    let page = backend.page_info(PageIndex(1))?;
    let width = page.geometry.crop_box.size.width;
    let height = page.geometry.crop_box.size.height;
    drop(backend);

    let annotations: Vec<WriteAnnotation> = IDS
        .iter()
        .zip(TEXTS)
        .enumerate()
        .map(|(index, (id, text))| WriteAnnotation {
            id: id.to_string(),
            page: PageIndex(1),
            kind: WriteAnnotationKind::FreeText,
            rect: Rect::new(
                72.0,
                height * 0.70 - index as f64 * 66.0,
                (width * 0.5).max(240.0),
                56.0,
            ),
            quads: Vec::new(),
            ink_paths: Vec::new(),
            line: None,
            line_arrow: false,
            stamp_style: None,
            stamp_image: None,
            border_width: 0.0,
            font_size: 16.0,
            alignment: AnnotationAlignment::Left,
            color: [20, 20, 20],
            opacity: 1.0,
            contents: Some(text.to_string()),
            author: Some("LyraReader CJK evidence".to_string()),
            modified: Some("D:20261018010000-07'00'".to_string()),
        })
        .collect();

    let report = save_annotated_pdf(
        &source,
        &destination,
        &annotations,
        &[],
        None,
        SaveMode::Copy,
    )?;
    println!("wrote {}", report.destination.display());
    println!("appended bytes: {}", report.appended_bytes);
    println!("written ids: {:?}", report.written_ids);
    Ok(())
}
