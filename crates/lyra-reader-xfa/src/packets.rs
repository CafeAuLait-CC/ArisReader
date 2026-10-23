//! Structural XFA detection and packet extraction.
//!
//! Detection is structural: the catalog's `/AcroForm` dictionary carries an `/XFA` entry. A
//! blank page is not evidence, and `/NeedsRendering` is reported but not required (some
//! producers omit it). The streams are opened with the standard security handler's empty user
//! password, because that is what "opens without a prompt" means for a permission-encrypted
//! form. lopdf does the RC4/AESV2 work; this crate never implements a cipher.

use crate::error::{Result, XfaError};
use lopdf::{Document, Object};
use std::path::Path;

/// One decrypted XFA packet, in the order the `/XFA` array lists it.
#[derive(Clone, Debug)]
pub struct Packet {
    /// The array key, e.g. `template`, `datasets`, `xdp:xdp` (the wrapper) or `</xdp:xdp>`.
    pub name: String,
    pub bytes: Vec<u8>,
}

impl Packet {
    pub fn is_wrapper(&self) -> bool {
        self.name.starts_with("xdp:") || self.name.starts_with("</xdp:")
    }

    /// A stable filename stem for the `xfa --out` command.
    pub fn file_stem(&self) -> String {
        let mut stem = String::new();
        for character in self.name.chars() {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                stem.push(character);
            } else if character == ':' || character == '<' || character == '/' {
                stem.push('_');
            }
        }
        let trimmed = stem.trim_matches('_');
        if trimmed.is_empty() {
            "packet".to_string()
        } else {
            trimmed.to_string()
        }
    }
}

/// What the structural read found.
#[derive(Clone, Debug)]
pub struct XfaFile {
    /// The file carries an encryption dictionary (even when the empty password opened it).
    pub encrypted: bool,
    /// The document was opened with the empty user password, so no prompt is needed.
    pub opened_with_empty_password: bool,
    /// The catalog's `/NeedsRendering` entry, when present.
    pub needs_rendering: bool,
    /// Whether `/AcroForm` and `/XFA` are both present. Always true in `Xfa`.
    pub has_acro_form: bool,
    pub packets: Vec<Packet>,
    /// Warnings from the structural read (a packet that could not be decompressed, an odd
    /// array, …). The layout may still be usable; the caller shows these in its skipped list.
    pub warnings: Vec<String>,
}

/// The result of looking at a file before choosing the normal or the XFA path.
#[derive(Clone, Debug)]
pub enum Detection {
    /// An ordinary PDF (possibly encrypted with a password the caller supplied).
    NotXfa { encrypted: bool },
    /// An XFA form, decrypted and ready to parse.
    Xfa(XfaFile),
    /// The file is encrypted and the empty/supplied password did not open it.
    PasswordRequired,
}

/// Reads `path` and classifies it. `password` is only used by the normal document path; XFA
/// support intentionally opens only the no-prompt case (the empty user password).
pub fn detect(path: &Path, password: Option<&str>) -> Result<Detection> {
    let document = match load(path, password) {
        Ok(document) => document,
        Err(error) => return classify_load_error(error),
    };
    let encrypted = document.was_encrypted() || document.is_encrypted();

    let Some(xfa) = catalog_xfa(&document) else {
        return Ok(Detection::NotXfa { encrypted });
    };

    let needs_rendering = document
        .catalog()
        .ok()
        .and_then(|catalog| catalog.get(b"NeedsRendering").ok())
        .and_then(|value| value.as_bool().ok())
        .unwrap_or(false);

    let resolved = resolve(&document, &xfa);
    let mut warnings = Vec::new();
    let packets = packets_from(&document, resolved, &mut warnings).map_err(XfaError::Malformed)?;
    if packets.is_empty() {
        return Err(XfaError::Malformed(
            "/AcroForm has an /XFA entry but it contains no packets".to_string(),
        ));
    }

    Ok(Detection::Xfa(XfaFile {
        encrypted,
        opened_with_empty_password: encrypted && password.is_none_or(str::is_empty),
        needs_rendering,
        has_acro_form: true,
        packets,
        warnings,
    }))
}

fn load(path: &Path, password: Option<&str>) -> std::result::Result<Document, lopdf::Error> {
    match password {
        Some(password) if !password.is_empty() => Document::load_with_password(path, password),
        _ => Document::load(path),
    }
}

fn classify_load_error(error: lopdf::Error) -> Result<Detection> {
    use lopdf::Error as PdfError;
    match &error {
        PdfError::Decryption(_) | PdfError::InvalidPassword => Ok(Detection::PasswordRequired),
        PdfError::IO(io) if io.kind() == std::io::ErrorKind::NotFound => {
            Err(XfaError::Io("the file does not exist".to_string()))
        }
        PdfError::IO(io) => Err(XfaError::Io(io.to_string())),
        other => Err(XfaError::Pdf(other.to_string())),
    }
}

/// Resolves the catalog's `/AcroForm /XFA` object, without requiring `/NeedsRendering`.
fn catalog_xfa(document: &Document) -> Option<Object> {
    let catalog = document.catalog().ok()?;
    let acro = resolve(document, catalog.get(b"AcroForm").ok()?);
    let dictionary = acro.as_dict().ok()?;
    let xfa = resolve(document, dictionary.get(b"XFA").ok()?);
    // A missing or null XFA is not a form.
    if xfa.is_null() {
        return None;
    }
    Some(xfa)
}

fn resolve(document: &Document, object: &Object) -> Object {
    match object {
        Object::Reference(id) => document.get_object(*id).cloned().unwrap_or(Object::Null),
        other => other.clone(),
    }
}

fn packets_from(
    document: &Document,
    xfa: Object,
    warnings: &mut Vec<String>,
) -> std::result::Result<Vec<Packet>, String> {
    match xfa {
        Object::Array(entries) => {
            if entries.len() % 2 != 0 {
                warnings.push(format!(
                    "the /XFA array has {} entries (an odd count); the last entry was ignored",
                    entries.len()
                ));
            }
            let mut packets = Vec::new();
            for pair in entries.chunks(2) {
                if pair.len() != 2 {
                    break;
                }
                let name = object_name(&pair[0])
                    .ok_or_else(|| "an /XFA array key is not a name or string".to_string())?;
                let value = resolve(document, &pair[1]);
                match value {
                    Object::Stream(stream) => match stream.decompressed_content() {
                        Ok(bytes) => packets.push(Packet { name, bytes }),
                        Err(error) => {
                            warnings
                                .push(format!("packet {name} could not be decompressed: {error}"));
                        }
                    },
                    Object::Reference(_) => {
                        // `resolve` has already followed one reference. A second one is a
                        // damaged file; report it rather than silently dropping the packet.
                        warnings.push(format!(
                            "packet {name} is a reference that does not resolve"
                        ));
                    }
                    _ => warnings.push(format!("packet {name} is not a stream")),
                }
            }
            Ok(packets)
        }
        Object::Stream(stream) => match stream.decompressed_content() {
            Ok(bytes) => Ok(vec![Packet {
                name: "xdp:xdp".to_string(),
                bytes,
            }]),
            Err(error) => Err(format!(
                "the /XFA stream could not be decompressed: {error}"
            )),
        },
        Object::Dictionary(dictionary) => {
            // XFA 2.6 allows the array to be wrapped in a dictionary; the real packet list is
            // not standard here, so report what is available instead of guessing.
            let mut found = Vec::new();
            for (key, value) in dictionary.iter() {
                let name = String::from_utf8_lossy(key).into_owned();
                let value = resolve(document, value);
                if let Ok(stream) = value.as_stream()
                    && let Ok(bytes) = stream.decompressed_content()
                {
                    found.push(Packet { name, bytes });
                }
            }
            if found.is_empty() {
                Err("/XFA is a dictionary without readable packets".to_string())
            } else {
                warnings.push("/XFA is a dictionary; its entries were read as packets".to_string());
                Ok(found)
            }
        }
        _ => Err("/XFA is neither an array nor a stream".to_string()),
    }
}

fn object_name(object: &Object) -> Option<String> {
    if let Ok(value) = object.as_str() {
        return Some(String::from_utf8_lossy(value).into_owned());
    }
    if let Ok(name) = object.as_name() {
        return Some(String::from_utf8_lossy(name).into_owned());
    }
    None
}

impl XfaFile {
    /// The packet whose name is `name` (case-insensitive).
    pub fn packet(&self, name: &str) -> Option<&Packet> {
        self.packets
            .iter()
            .find(|packet| packet.name.eq_ignore_ascii_case(name))
    }

    /// A whole-XDP packet: one stream that contains `<template>`, `<datasets>` and friends.
    pub fn xdp_packet(&self) -> Option<&Packet> {
        self.packet("xdp:xdp").filter(|packet| {
            packet.bytes.windows(9).any(|window| window == b"<template")
                || packet
                    .bytes
                    .windows(10)
                    .any(|window| window == b"<datasets")
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packet_names_become_safe_file_stems() {
        let packet = Packet {
            name: "xdp:xdp".to_string(),
            bytes: Vec::new(),
        };
        assert_eq!(packet.file_stem(), "xdp_xdp");
        let packet = Packet {
            name: "</xdp:xdp>".to_string(),
            bytes: Vec::new(),
        };
        assert_eq!(packet.file_stem(), "xdp_xdp");
    }
}
