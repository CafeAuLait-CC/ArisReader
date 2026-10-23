//! Failures that a caller must tell apart: "not an XFA form" is normal, while "needs a
//! password" is the same state the normal PDF path reports so the shell can prompt.

use std::fmt;

pub type Result<T> = std::result::Result<T, XfaError>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum XfaError {
    Io(String),
    Pdf(String),
    /// The file is encrypted and the supplied (or empty) password did not open it.
    PasswordRequired,
    /// A structural read found an XFA form but a packet could not be read.
    Malformed(String),
    /// The layout/font/image step could not produce a page.
    Render(String),
}

impl fmt::Display for XfaError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(detail) => write!(formatter, "could not read the PDF: {detail}"),
            Self::Pdf(detail) => write!(formatter, "the PDF could not be parsed: {detail}"),
            Self::PasswordRequired => write!(formatter, "the document is password protected"),
            Self::Malformed(detail) => write!(formatter, "the XFA packet is malformed: {detail}"),
            Self::Render(detail) => {
                write!(formatter, "the XFA form could not be rendered: {detail}")
            }
        }
    }
}

impl std::error::Error for XfaError {}
