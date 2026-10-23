//! Read-only XFA form support.
//!
//! # What this crate does
//!
//! 1. [`packets::detect`] reads `/AcroForm /XFA` structurally. If the file is encrypted with an
//!    empty user password, the standard security handler is used (through `lopdf`), so a
//!    permission-encrypted form opens without a prompt.
//! 2. [`template::parse_template`] and [`dataset::DataSet::parse`] turn the XML packets into a
//!    layout tree and the saved values plus its LOV tables.
//! 3. [`layout::render`] produces pages of static drawing operations, and [`pdfgen::generate`]
//!    writes them as a small PDF held **in memory**.
//!
//! The source file is only read. The synthetic PDF is what the reader opens, so zoom, scroll,
//! search, text selection and summaries use the existing pipeline. The document is read-only:
//! there is nothing in the synthetic PDF to fill, annotate or edit, and the caller refuses
//! write-back with [`XfaStatus::read_only_reason`].
//!
//! # Honest fallback
//!
//! Unsupported field types, fonts, images and layout constructs are named in
//! [`XfaStatus::skipped`] / [`RenderedDocument::skipped`]; they are not silently dropped. If the
//! template cannot be parsed at all, [`prepare`] returns a status with `rendered: false` and
//! `error: Some(...)`, and the caller opens the original PDF (a blank page) while saying so.

pub mod dataset;
pub mod error;
pub mod image;
pub mod layout;
pub mod model;
pub mod packets;
pub mod pdfgen;
pub mod template;
pub mod text;
pub mod units;
pub mod xml;

pub use dataset::DataSet;
pub use error::{Result, XfaError};
pub use layout::{RenderedDocument, RenderedPage};
pub use model::PageSize;
pub use packets::{Detection, Packet, XfaFile, load_document};
pub use template::Template;

use std::path::Path;

/// The one read-only sentence every XFA write refusal and the shell banner use.
pub const READ_ONLY_REASON: &str = "This PDF is an XFA form. LyraReader renders it read-only \
from its XML; the file is never modified. Form filling, annotation, editing and saving edits \
are unavailable. Reading, zoom, search, selection and summaries still work.";

/// What the reader must know about an XFA document after it opened.
#[derive(Clone, Debug, Default)]
pub struct XfaStatus {
    /// Packet names in `/XFA` order (`xdp:xdp`, `config`, `template`, …).
    pub packet_names: Vec<String>,
    pub packet_bytes: usize,
    /// The source carries an encryption dictionary (even when opened without a prompt).
    pub encrypted: bool,
    pub needs_rendering: bool,
    /// Whether a synthetic PDF was produced and handed to the renderer.
    pub rendered: bool,
    pub page_count: u32,
    pub field_count: u32,
    /// The things the renderer could not draw, in a person's words. Never empty for a partial
    /// form; the shell shows this line in the status area and the banner.
    pub skipped: Vec<String>,
    /// Set only when the template could not be rendered; the caller then opens the original.
    pub error: Option<String>,
    pub read_only_reason: String,
}

/// A detected XFA form with everything derived from its packets.
#[derive(Clone, Debug)]
pub struct PreparedXfa {
    pub file: XfaFile,
    pub template: Option<Template>,
    pub dataset: DataSet,
    pub rendered: Option<RenderedDocument>,
    /// The synthetic PDF. Present only when `rendered` is.
    pub pdf: Option<Vec<u8>>,
    pub status: XfaStatus,
}

/// Detect, parse and render `path` in one call. `Ok(None)` means an ordinary PDF.
///
/// The XFA path intentionally ignores a caller password: the supported case is the empty user
/// password. A file that still needs a password returns [`XfaError::PasswordRequired`], which
/// the shell translates into the same prompt an ordinary encrypted PDF gets.
pub fn prepare(path: &Path, password: Option<&str>) -> Result<Option<PreparedXfa>> {
    let document = packets::load_document(path, password)?;
    prepare_in_document(&document, password)
}

/// Builds the XFA document from a PDF that the caller has already loaded structurally.
///
/// This is the shared-parse entry point used by the FFI: the same `lopdf::Document` supplies
/// the XFA packets and the signature evidence, so an open reads the bytes once.
pub fn prepare_in_document(
    document: &lopdf::Document,
    password: Option<&str>,
) -> Result<Option<PreparedXfa>> {
    let detection = packets::detect_in_document(document, password)?;
    let file = match detection {
        Detection::NotXfa { .. } => return Ok(None),
        Detection::PasswordRequired => return Err(XfaError::PasswordRequired),
        Detection::Xfa(file) => file,
    };
    let mut skipped: Vec<String> = file.warnings.clone();
    let template_bytes = file
        .packet("template")
        .or_else(|| file.xdp_packet())
        .map(|packet| packet.bytes.clone());
    let dataset_bytes = file
        .packet("datasets")
        .or_else(|| file.xdp_packet())
        .map(|packet| packet.bytes.clone());

    let template = match template_bytes {
        Some(bytes) => match template::parse_template(&bytes) {
            Ok(template) => Some(template),
            Err(error) => {
                skipped.push(format!("the template packet could not be read: {error}"));
                None
            }
        },
        None => {
            skipped.push("the /XFA array has no template packet".to_string());
            None
        }
    };
    let dataset = match dataset_bytes {
        Some(bytes) => match DataSet::parse(&bytes) {
            Ok(dataset) => dataset,
            Err(error) => {
                skipped.push(format!("the datasets packet could not be read: {error}"));
                DataSet::default()
            }
        },
        None => {
            skipped.push(
                "the /XFA array has no datasets packet; template defaults are used".to_string(),
            );
            DataSet::default()
        }
    };

    let mut status = XfaStatus {
        packet_names: file
            .packets
            .iter()
            .map(|packet| packet.name.clone())
            .collect(),
        packet_bytes: file.packets.iter().map(|packet| packet.bytes.len()).sum(),
        encrypted: file.encrypted,
        needs_rendering: file.needs_rendering,
        rendered: false,
        page_count: 0,
        field_count: template
            .as_ref()
            .map(|template| template.fields().len() as u32)
            .unwrap_or(0),
        skipped: Vec::new(),
        error: None,
        read_only_reason: READ_ONLY_REASON.to_string(),
    };

    let mut rendered = None;
    let mut pdf = None;
    if let Some(template) = &template {
        let document = layout::render(template, &dataset);
        status.page_count = document.pages.len() as u32;
        status.rendered = true;
        skipped.extend(document.skipped.iter().cloned());
        let (bytes, missing) = pdfgen::generate(&document);
        if !missing.is_empty() {
            let text: String = missing.iter().collect();
            skipped.push(format!(
                "characters outside WinAnsi were written as `?`: {text}"
            ));
        }
        pdf = Some(bytes);
        rendered = Some(document);
    } else {
        status.error = Some(
            "the XFA template packet is missing or malformed; the original PDF is shown instead"
                .to_string(),
        );
    }
    if file.encrypted && !file.opened_with_empty_password {
        skipped.push(
            "the document is encrypted; it was opened with the password supplied by the caller"
                .to_string(),
        );
    }
    skipped.sort();
    skipped.dedup();
    status.skipped = skipped;
    Ok(Some(PreparedXfa {
        file,
        template,
        dataset,
        rendered,
        pdf,
        status,
    }))
}

/// Writes the decrypted packets into `directory` and returns their paths.
///
/// This is the repeatable evidence for the phase-1 report: the next person can run
/// `lyra-reader-cli xfa <file> --out <dir>` and inspect exactly the XML the renderer saw.
pub fn write_packets(file: &XfaFile, directory: &Path) -> Result<Vec<std::path::PathBuf>> {
    std::fs::create_dir_all(directory)
        .map_err(|error| XfaError::Io(format!("{}: {error}", directory.display())))?;
    let mut written = Vec::new();
    for (index, packet) in file.packets.iter().enumerate() {
        let path = directory.join(format!("packet-{:02}-{}.xml", index, packet.file_stem()));
        std::fs::write(&path, &packet.bytes)
            .map_err(|error| XfaError::Io(format!("{}: {error}", path.display())))?;
        written.push(path);
    }
    Ok(written)
}
