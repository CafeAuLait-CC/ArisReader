//! Bindings generator entry point.
//!
//! UniFFI's recommended layout: the generator ships inside the crate that defines the
//! interface, so a checkout can regenerate bindings without installing a tool.
//!
//! `scripts/build-rust.sh` invokes:
//!
//! ```text
//! cargo run -p lyra-reader-ffi --bin uniffi-bindgen -- generate \
//!     --library target/release/liblyra_reader_ffi.dylib \
//!     --language swift --out-dir apps/macos/Sources/LyraReaderBindings
//! ```

fn main() {
    uniffi::uniffi_bindgen_main()
}
