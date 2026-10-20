//! Digital-signature detection for the write policy.
//!
//! A signed PDF is opened **read-only in place**: rewriting it would invalidate the signature
//! even when the new bytes are semantically harmless, and a reader that quietly breaks a
//! signature is worse than one that says it will not write. Deriving a **new file** is allowed;
//! the derived copy is stripped of signature material because its bytes are no longer covered
//! by the signature. The shell needs the decision at open time, so detection is structural and
//! paid once per document.
//!
//! # Evidence
//!
//! A document is signed when **any** of these is present, and the returned evidence names
//! which one(s) made the decision:
//!
//! 1. `/AcroForm /SigFlags` with bit 1 (signatures exist) set;
//! 2. `/Perms /DocMDP` in the catalog (a certification policy);
//! 3. a signature field (`/FT /Sig`, inherited through `/Kids`) with a non-empty `/V`;
//! 4. a `/DSS` long-term-validation store in the catalog.
//!
//! The check reads the document's dictionaries once through the same `lopdf` loader the form
//! and properties readers use; it does not walk pages, text or annotations. PDFium's own
//! signature count is a fallback for a structure `lopdf` cannot parse — it is a state read on
//! the already-open document, not a parse — and is reported as evidence only when the
//! structural read found nothing.
//!
//! # Why not only PDFium's count
//!
//! `FPDF_GetSignatureCount` is the cheapest signal, but it answers one question ("are there
//! signature fields PDFium recognises?"). A document prepared for signing carries `/SigFlags`
//! and possibly `/DSS` before any signature exists; a DocMDP policy lives in the catalog, not
//! in a field. Those are exactly the cases a write must not ignore, so the dictionary read is
//! the primary one.

use crate::forms::{decode_text_string, load_document, resolve};
use lopdf::{Dictionary, Document, Object};

/// One kind of evidence that a document is signed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignatureEvidenceKind {
    /// `/AcroForm /SigFlags` has the signatures-exist bit set.
    SigFlags,
    /// The catalog has a `/Perms /DocMDP` certification policy.
    DocMdp,
    /// A `/FT /Sig` field has a non-empty `/V`.
    SignatureField,
    /// The catalog has a `/DSS` long-term-validation store.
    Dss,
    /// PDFium reports at least one signature object; used when the structural read failed or
    /// found nothing.
    Pdfium,
}

impl SignatureEvidenceKind {
    /// Stable machine name across the FFI, used by the shell and the checks.
    pub fn code(self) -> &'static str {
        match self {
            Self::SigFlags => "sigFlags",
            Self::DocMdp => "docMdp",
            Self::SignatureField => "signatureField",
            Self::Dss => "dss",
            Self::Pdfium => "pdfium",
        }
    }

    /// Short human label for the read-only banner.
    pub fn label(self) -> &'static str {
        match self {
            Self::SigFlags => "signature flags in the form dictionary",
            Self::DocMdp => "a DocMDP certification policy",
            Self::SignatureField => "a signed signature field",
            Self::Dss => "a long-term validation store",
            Self::Pdfium => "a signature PDFium recognises",
        }
    }
}

/// One piece of evidence, with the detail a person can read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignatureEvidence {
    pub kind: SignatureEvidenceKind,
    pub detail: String,
}

/// What the signature check found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SignatureStatus {
    pub evidence: Vec<SignatureEvidence>,
}

impl SignatureStatus {
    pub fn is_signed(&self) -> bool {
        !self.evidence.is_empty()
    }

    /// `"signature flags in the form dictionary; a signed signature field"`, or an empty
    /// string for an unsigned document. The same words reach the banner and every in-place
    /// write refusal.
    pub fn summary(&self) -> String {
        self.evidence
            .iter()
            .map(|evidence| evidence.kind.label())
            .collect::<Vec<_>>()
            .join("; ")
    }

    /// The sentence every write command refuses with. One string, so no two write paths can
    /// explain the read-only state differently.
    pub fn read_only_reason(&self) -> Option<String> {
        if !self.is_signed() {
            return None;
        }
        Some(format!(
            "This document is digitally signed ({}); it opens read-only in place — edits can be \
             saved to a copy, and the signed original is never modified. A modified copy has its \
             signature fields removed, because the copy's bytes are no longer covered by the \
             signature.",
            self.summary()
        ))
    }

    fn push(&mut self, kind: SignatureEvidenceKind, detail: impl Into<String>) {
        if !self.evidence.iter().any(|evidence| evidence.kind == kind) {
            self.evidence.push(SignatureEvidence {
                kind,
                detail: detail.into(),
            });
        }
    }
}

/// Reads the document and reports every signature evidence kind it carries.
///
/// `pdfium_signatures` is `FPDF_GetSignatureCount` for the already-open document. It is only
/// consulted when the dictionary read finds no evidence or cannot run: the structural sources
/// are more specific and are what the policy is defined on.
pub fn detect_signature(
    path: &std::path::Path,
    password: Option<&str>,
    pdfium_signatures: u32,
) -> SignatureStatus {
    let mut status = SignatureStatus::default();
    let parsed = match load_document(path, password) {
        Ok(document) => {
            read_evidence(&document, &mut status);
            true
        }
        Err(_) => false,
    };
    // PDFium's count includes an *unsigned* signature field, so it is not evidence on its own
    // (a form prepared for signing must stay writable). It is a fallback only when the
    // dictionary read could not run: a structure we cannot read cannot prove the document
    // unsigned, and a real signature is the one thing PDFium can still see.
    if !parsed && !status.is_signed() && pdfium_signatures > 0 {
        let noun = if pdfium_signatures == 1 {
            "one digital signature"
        } else {
            "digital signatures"
        };
        status.push(
            SignatureEvidenceKind::Pdfium,
            format!("PDFium reports {pdfium_signatures} {noun}"),
        );
    }
    status
}

fn read_evidence(document: &Document, status: &mut SignatureStatus) {
    let Some(catalog) = catalog(document) else {
        return;
    };

    if let Some(flags) = acro_form(document)
        .and_then(|form| form.get(b"SigFlags").ok())
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_i64().ok())
        && flags & 1 != 0
    {
        status.push(
            SignatureEvidenceKind::SigFlags,
            format!("/AcroForm /SigFlags is {flags}: the signatures-exist bit is set"),
        );
    }

    if let Some(perms) = catalog
        .get(b"Perms")
        .ok()
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_dict().ok())
        && let Some(doc_mdp) = perms
            .get(b"DocMDP")
            .ok()
            .and_then(|object| resolve(document, object))
    {
        let permission = doc_mdp
            .as_dict()
            .ok()
            .and_then(|dictionary| dictionary.get(b"P").ok())
            .and_then(|object| object.as_i64().ok());
        status.push(
            SignatureEvidenceKind::DocMdp,
            match permission {
                Some(permission) => {
                    format!("/Perms /DocMDP certification policy (permission {permission})")
                }
                None => "/Perms /DocMDP certification policy".to_string(),
            },
        );
    }

    if let Some(form) = acro_form(document) {
        let mut signed_fields = Vec::new();
        if let Ok(fields) = form.get(b"Fields").and_then(|object| object.as_array()) {
            collect_signature_fields(document, fields, None, &mut signed_fields, 0);
        }
        if !signed_fields.is_empty() {
            let names = signed_fields
                .iter()
                .take(3)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");
            let count = signed_fields.len();
            let suffix = if count > 3 {
                format!(" and {} more", count - 3)
            } else {
                String::new()
            };
            status.push(
                SignatureEvidenceKind::SignatureField,
                format!("{count} signature field(s) carry a value: {names}{suffix}"),
            );
        }
    }

    if let Some(dss) = catalog
        .get(b"DSS")
        .ok()
        .and_then(|object| resolve(document, object))
        && dss.as_dict().is_ok()
    {
        status.push(
            SignatureEvidenceKind::Dss,
            "/DSS long-term validation store is present".to_string(),
        );
    }
}

const MAX_SIGNATURE_FIELD_DEPTH: usize = 64;

fn collect_signature_fields(
    document: &Document,
    fields: &[Object],
    inherited_type: Option<&[u8]>,
    signed: &mut Vec<String>,
    depth: usize,
) {
    if depth > MAX_SIGNATURE_FIELD_DEPTH {
        return;
    }
    for field in fields {
        let Some(dictionary) = resolve(document, field).and_then(|object| object.as_dict().ok())
        else {
            continue;
        };
        let field_type = dictionary
            .get(b"FT")
            .ok()
            .and_then(|object| resolve(document, object))
            .and_then(|object| object.as_name().ok())
            .or(inherited_type);
        let is_signature = field_type == Some(b"Sig");
        if is_signature
            && dictionary
                .get(b"V")
                .ok()
                .and_then(|object| resolve(document, object))
                .is_some_and(|value| !is_empty_value(document, value))
        {
            let name = dictionary
                .get(b"T")
                .ok()
                .and_then(|object| resolve(document, object))
                .and_then(|object| object.as_str().ok())
                .map(decode_text_string)
                .filter(|name| !name.is_empty())
                .unwrap_or_else(|| "(unnamed field)".to_string());
            signed.push(name);
            // The children of a signature field are its widgets; they cannot add evidence.
            continue;
        }
        if let Ok(kids) = dictionary.get(b"Kids").and_then(|object| object.as_array()) {
            collect_signature_fields(document, kids, field_type, signed, depth + 1);
        }
    }
}

fn is_empty_value(document: &Document, value: &Object) -> bool {
    match value {
        Object::Null => true,
        Object::String(bytes, _) => bytes.is_empty(),
        Object::Array(array) => array.is_empty(),
        Object::Dictionary(dictionary) => dictionary.is_empty(),
        Object::Stream(stream) => stream.content.is_empty(),
        Object::Reference(_) => {
            resolve(document, value).is_none_or(|value| is_empty_value(document, value))
        }
        _ => false,
    }
}

fn catalog(document: &Document) -> Option<&Dictionary> {
    document
        .trailer
        .get(b"Root")
        .ok()
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_dict().ok())
}

fn acro_form(document: &Document) -> Option<&Dictionary> {
    catalog(document)?
        .get(b"AcroForm")
        .ok()
        .and_then(|object| resolve(document, object))
        .and_then(|object| object.as_dict().ok())
}

#[cfg(all(test, feature = "pdfium"))]
mod tests {
    use super::*;
    use crate::test_support::fixture;

    fn codes(status: &SignatureStatus) -> Vec<&'static str> {
        status
            .evidence
            .iter()
            .map(|evidence| evidence.kind.code())
            .collect()
    }

    #[test]
    fn signature_flags_and_a_signed_field_are_detected() {
        let status = detect_signature(&fixture("signed-signature.pdf"), None, 0);
        assert!(status.is_signed(), "the signed fixture must be detected");
        assert!(codes(&status).contains(&"sigFlags"), "{:?}", status);
        assert!(codes(&status).contains(&"signatureField"), "{:?}", status);
        let reason = status.read_only_reason().expect("a refusal reason");
        assert!(reason.contains("signature flags"), "{reason}");
        assert!(reason.contains("signed signature field"), "{reason}");
        assert!(reason.contains("edits can be saved to a copy"), "{reason}");
    }

    #[test]
    fn a_doc_mdp_policy_is_detected_without_a_signature_field() {
        let status = detect_signature(&fixture("signed-docmdp.pdf"), None, 0);
        assert!(status.is_signed(), "the DocMDP fixture must be detected");
        assert_eq!(codes(&status), vec!["docMdp"], "{:?}", status);
        assert!(status.evidence[0].detail.contains("/DocMDP"));
    }

    #[test]
    fn ordinary_documents_are_not_signed() {
        for name in ["text-page.pdf", "form-fields.pdf", "annotated-replies.pdf"] {
            let status = detect_signature(&fixture(name), None, 0);
            assert!(
                !status.is_signed(),
                "{name} was detected as signed: {:?}",
                status.evidence
            );
            assert!(status.read_only_reason().is_none());
        }
    }

    #[test]
    fn a_signature_field_without_a_value_is_not_signed() {
        // `form-fields.pdf` has a `/FT /Sig` widget; only a non-empty `/V` makes it signed.
        let document = load_document(&fixture("form-fields.pdf"), None).expect("load");
        let mut status = SignatureStatus::default();
        read_evidence(&document, &mut status);
        assert!(!status.is_signed(), "{:?}", status.evidence);
    }

    #[test]
    fn pdfium_evidence_is_a_fallback_only() {
        // An unsigned field is counted by PDFium; the structural read proves it is not signed,
        // so no evidence is reported.
        let unsigned = detect_signature(&fixture("form-fields.pdf"), None, 2);
        assert!(!unsigned.is_signed(), "{:?}", unsigned.evidence);

        // A structure that cannot be read falls back to PDFium's count.
        let missing = fixture("text-page.pdf").with_file_name("does-not-exist.pdf");
        let fallback = detect_signature(&missing, None, 2);
        assert_eq!(codes(&fallback), vec!["pdfium"]);
        let signed = detect_signature(&fixture("signed-signature.pdf"), None, 2);
        assert!(!codes(&signed).contains(&"pdfium"), "{:?}", signed);
    }
}
