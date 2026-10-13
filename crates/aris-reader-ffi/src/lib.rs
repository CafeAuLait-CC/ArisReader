//! External interface layer: **UniFFI control plane** + **hand-written C ABI data plane**.
//!
//! See `docs/05-ffi.md` and `docs/adr/0004`.
//!
//! # Why the mix
//!
//! - The control plane (object handles, records/enums, `Result` → `throws`, event callbacks) uses **UniFFI**:
//!   the API surface keeps growing, so hand-writing it is not realistic.
//! - The data plane (`MTLDevice`/`CAMetalLayer` raw pointers, `present`, ABI version) uses a **hand-written C ABI**:
//!   raw pointers and thread semantics cannot be expressed in UniFFI's type system, and there are few of
//!   them (about 10 functions).
//!
//! # Hard lifetime rules (GPU part)
//!
//! 1. The `CAMetalLayer` must be created before [`aris_reader_surface_attach`] and may only be released
//!    after [`aris_reader_surface_detach`] (an explicit contract of the wgpu Metal backend);
//! 2. The window shutdown order is fixed: `detach_surface` → `aris_reader_surface_detach` → release the layer;
//! 3. Layer operations may only run on the UI main thread; this layer forwards to the GPU thread internally,
//!    and the UI thread does not wait.

#![allow(clippy::missing_safety_doc)]
// This is the **only** place in the project where `unsafe` is expected (raw pointers / foreign ABI),
// so the workspace `unsafe_code` lint is explicitly waived here; every function must still document
// its Safety contract.
#![allow(unsafe_code)]

use std::ffi::c_void;

/// ABI version. **Must be bumped whenever the signature or semantics of any exported function changes**.
pub const ABI_VERSION: u32 = 1;

/// C ABI return codes (0 = success, kept separate from Rust's `Result` so the C side can check them).
pub mod code {
    pub const OK: i32 = 0;
    pub const ERR_INVALID_ARGUMENT: i32 = 1;
    pub const ERR_NOT_IMPLEMENTED: i32 = 2;
    pub const ERR_NOT_INITIALIZED: i32 = 3;
    pub const ERR_GPU_UNAVAILABLE: i32 = 4;
    pub const ERR_GPU_DEVICE_LOST: i32 = 5;
    pub const ERR_INTERNAL: i32 = 6;
}

/// Returns the ABI version (checked by Swift at startup to avoid random crashes caused by bindings that do not match the library).
///
/// # Safety
///
/// Takes no arguments and has no side effects; may be called from any thread.
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_abi_version() -> u32 {
    ABI_VERSION
}

/// Initialize the GPU (creates the wgpu instance/adapter/device).
///
/// `flags`: bit0 = enable the validation layers (development), bit1 = request a low-power adapter.
///
/// TODO(T0.4): wire this up to `aris_reader_gpu::GpuContext::new`.
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_gpu_init(_flags: u32) -> i32 {
    code::ERR_NOT_IMPLEMENTED
}

/// Option A (`docs/adr/0003`): lend the internal `MTLDevice` pointer so Swift can create the `CAMetalLayer`.
///
/// A `null` return means the GPU is not initialized or the option is unavailable. **Ownership is not
/// transferred**: the pointer is valid for as long as [`GpuContext`](aris_reader_gpu::GpuContext) lives.
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_gpu_metal_device_ptr() -> *mut c_void {
    std::ptr::null_mut()
}

/// Register a `CAMetalLayer` as a rendering surface.
///
/// # Safety
///
/// `layer` must be a valid `CAMetalLayer` pointer, and it must stay alive until after
/// [`aris_reader_surface_detach`] has returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_surface_attach(
    _surface_id: u64,
    layer: *mut c_void,
    _width_px: u32,
    _height_px: u32,
    _scale: f64,
) -> i32 {
    if layer.is_null() {
        return code::ERR_INVALID_ARGUMENT;
    }
    code::ERR_NOT_IMPLEMENTED
}

/// Update the surface size/scale (window resize, screen change).
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_surface_resize(
    _surface_id: u64,
    _width_px: u32,
    _height_px: u32,
    _scale: f64,
) -> i32 {
    code::ERR_NOT_IMPLEMENTED
}

/// Request presentation of one frame. `epoch` is used to drop stale frames (the host and the engine track it independently).
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_surface_present(_surface_id: u64, _epoch: u64) -> i32 {
    code::ERR_NOT_IMPLEMENTED
}

/// Unregister a surface (only after this may Swift release the corresponding `CAMetalLayer`).
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_surface_detach(_surface_id: u64) -> i32 {
    code::ERR_NOT_IMPLEMENTED
}

/// Shut down the GPU (releases the device and all textures; call before the process exits).
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_gpu_shutdown() -> i32 {
    code::OK
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abi_version_is_stable() {
        let version = aris_reader_abi_version();
        assert_eq!(version, ABI_VERSION);
        assert!(version > 0, "ABI versions start at 1; 0 is reserved");
    }

    #[test]
    fn null_layer_is_rejected() {
        // SAFETY: a null pointer is passed in, so the function returns an error code before dereferencing anything.
        let rc = unsafe { aris_reader_surface_attach(1, std::ptr::null_mut(), 100, 100, 2.0) };
        assert_eq!(rc, code::ERR_INVALID_ARGUMENT);
    }
}
