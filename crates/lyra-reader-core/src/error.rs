//! Unified error type.
//!
//! When an error crosses the FFI boundary it is mapped to a Swift `throws` (see `docs/05-ffi.md` §5):
//! `code` is a stable identifier (used for localization and documentation), `message` is a
//! human-readable English summary, and `detail` is optional technical detail (for logs).

use std::fmt;

/// Error severity, which determines how the UI handles the error.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Severity {
    /// Recoverable: e.g. a single page fails to render; continue with placeholder content without interrupting the user.
    Recoverable,
    /// Document-level: e.g. open failure or wrong password; the user must be notified.
    Document,
    /// Fatal: e.g. GPU device loss or a broken internal invariant; requires a rebuild or restart.
    Fatal,
}

/// Stable error codes (**do not change the semantics of existing variants**; only append).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorCode {
    Io,
    NotFound,
    InvalidArgument,
    NotReady,
    Cancelled,
    Encrypted,
    WrongPassword,
    CorruptDocument,
    /// The document is read-only by policy (a signed PDF), so writing is refused.
    ReadOnly,
    UnsupportedFeature,
    BackendUnavailable,
    RenderFailed,
    GpuUnavailable,
    GpuDeviceLost,
    Internal,
}

impl ErrorCode {
    /// Localization key (`docs/04-ui-ux.md` §9).
    pub fn localization_key(self) -> &'static str {
        match self {
            Self::Io => "error.io",
            Self::NotFound => "error.not_found",
            Self::InvalidArgument => "error.invalid_argument",
            Self::NotReady => "error.not_ready",
            Self::Cancelled => "error.cancelled",
            Self::Encrypted => "error.encrypted",
            Self::WrongPassword => "error.encrypted.wrong_password",
            Self::CorruptDocument => "error.corrupt_document",
            Self::ReadOnly => "error.read_only",
            Self::UnsupportedFeature => "error.unsupported_feature",
            Self::BackendUnavailable => "error.backend_unavailable",
            Self::RenderFailed => "error.render_failed",
            Self::GpuUnavailable => "error.gpu_unavailable",
            Self::GpuDeviceLost => "error.gpu_device_lost",
            Self::Internal => "error.internal",
        }
    }

    /// Default severity.
    pub fn default_severity(self) -> Severity {
        match self {
            Self::RenderFailed | Self::Cancelled | Self::NotReady => Severity::Recoverable,
            Self::GpuUnavailable | Self::GpuDeviceLost | Self::Internal => Severity::Fatal,
            _ => Severity::Document,
        }
    }
}

/// LyraReader unified error.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LyraReaderError {
    pub code: ErrorCode,
    pub message: String,
    pub detail: Option<String>,
    pub severity: Severity,
}

impl LyraReaderError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            detail: None,
            severity: code.default_severity(),
        }
    }

    pub fn with_detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }

    pub fn with_severity(mut self, severity: Severity) -> Self {
        self.severity = severity;
        self
    }

    pub fn not_implemented(what: &str) -> Self {
        Self::new(
            ErrorCode::UnsupportedFeature,
            format!("not implemented yet: {what}"),
        )
    }
}

impl fmt::Display for LyraReaderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)?;
        if let Some(detail) = &self.detail {
            write!(f, " ({detail})")?;
        }
        Ok(())
    }
}

impl std::error::Error for LyraReaderError {}

impl From<std::io::Error> for LyraReaderError {
    fn from(err: std::io::Error) -> Self {
        let code = match err.kind() {
            std::io::ErrorKind::NotFound => ErrorCode::NotFound,
            std::io::ErrorKind::InvalidInput => ErrorCode::InvalidArgument,
            _ => ErrorCode::Io,
        };
        Self::new(code, err.to_string())
    }
}

pub type Result<T> = std::result::Result<T, LyraReaderError>;
