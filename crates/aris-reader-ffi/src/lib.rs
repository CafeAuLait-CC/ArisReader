//! External interface layer: **UniFFI control plane** + **hand-written C ABI data plane**.
//!
//! See `docs/05-ffi.md` and `docs/adr/0004`.
//!
//! # Why the mix
//!
//! - The control plane (object handles, records/enums, `Result` → `throws`, event callbacks) uses **UniFFI**:
//!   the API surface keeps growing, so hand-writing it is not realistic.
//! - The data plane (`MTLDevice`/`CAMetalLayer` raw pointers, frame presentation, ABI version) uses a
//!   **hand-written C ABI**: raw pointers and thread semantics cannot be expressed in UniFFI's type system,
//!   and there are few of them (about 10 functions).
//!
//! # Hard lifetime rules (GPU part)
//!
//! 1. The `CAMetalLayer` must be created before [`aris_reader_surface_attach`] and may only be released
//!    after [`aris_reader_surface_detach`] (an explicit contract of the wgpu Metal backend);
//! 2. The window shutdown order is fixed: `detach_surface` → `aris_reader_surface_detach` → release the layer;
//! 3. Layer operations may only run on the UI main thread; this layer serialises internally.
//!
//! # Device ownership (M0 T0.4 spike result)
//!
//! Both sides use the process-wide default Metal device: wgpu's Metal backend and AppKit's
//! `CAMetalLayer` end up with the same `MTLDevice`, so no hand-off is needed.
//! [`aris_reader_gpu_metal_device_ptr`] therefore stays as a documented, always-null probe for the
//! alternative strategy described in `docs/adr/0003`.

#![allow(clippy::missing_safety_doc)]
// This is the **only** place in the project where `unsafe` is expected (raw pointers / foreign ABI),
// so the workspace `unsafe_code` lint is explicitly waived here; every function must still document
// its Safety contract.
#![allow(unsafe_code)]

use aris_reader_gpu::{GpuContext, SurfaceConfig, SurfaceId, SurfaceTarget};
use std::ffi::c_void;
use std::sync::Mutex;

// UniFFI scaffolding for the control plane declared in `api` (T0.8). The generated
// Swift bindings and their C header are produced by `scripts/build-rust.sh`.
uniffi::setup_scaffolding!();

pub mod api;
pub use api::{ArisEngine, ArisFfiError, DocumentSummary};

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

/// Frame statistics handed back to the host after [`aris_reader_surface_render`].
///
/// `#[repr(C)]` so Swift can read it with a plain `struct` — see `docs/05-ffi.md` §5.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct ArisFrameStats {
    /// 1 when the frame reached the window server.
    pub presented: u32,
    pub width: u32,
    pub height: u32,
    /// 1 when the surface texture format is sRGB.
    pub srgb: u32,
    /// Centre pixel read back as 0xAARRGGBB (BGRA byte order), 0 when unavailable.
    pub center_bgra: u32,
    pub elapsed_us: u32,
    /// Frames rendered since the context was created (all surfaces).
    pub frame_index: u64,
    /// Frames rendered by this surface.
    pub surface_frame_index: u64,
}

/// The process-wide GPU context, created by [`aris_reader_gpu_init`].
///
/// A mutex rather than a lock-free cell: every entry point here is expected to be
/// called from the UI thread at display rate, and the GPU work is submitted in one
/// batch per frame. T1.7 moves this to a dedicated GPU thread with a command queue.
static GPU: Mutex<Option<GpuContext>> = Mutex::new(None);

/// Returns the ABI version (checked by Swift at startup to avoid random crashes caused by bindings that do not match the library).
///
/// # Safety
///
/// Takes no arguments and has no side effects; may be called from any thread.
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_abi_version() -> u32 {
    ABI_VERSION
}

/// Initializes the GPU (creates the wgpu instance/adapter/device).
///
/// `flags`: bit0 = enable the validation layers (development), bit1 = request a low-power adapter.
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_gpu_init(flags: u32) -> i32 {
    let validation = flags & 1 != 0;

    let mut guard = match GPU.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    if guard.is_some() {
        return code::OK; // Idempotent: Swift may call this from every canvas view.
    }

    match GpuContext::new(validation) {
        Ok(context) => {
            println!(
                "aris-gpu: device ready — {} (validation: {})",
                context.adapter_description(),
                validation
            );
            *guard = Some(context);
            code::OK
        }
        Err(error) => {
            eprintln!("aris-gpu: initialization failed: {error}");
            code::ERR_GPU_UNAVAILABLE
        }
    }
}

/// Always returns `null`: the spike uses the process-wide default Metal device on both sides.
///
/// Kept (instead of removing it) so the alternative strategy in `docs/adr/0003` stays
/// expressible without an ABI change; Swift treats `null` as "create your own layer device".
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_gpu_metal_device_ptr() -> *mut c_void {
    std::ptr::null_mut()
}

/// Registers a `CAMetalLayer` as a rendering surface and returns its opaque id.
///
/// # Safety
///
/// `layer` must be a valid `CAMetalLayer` pointer that stays alive until after
/// [`aris_reader_surface_detach`] has returned with the id written to `out_surface_id`.
/// `out_surface_id` must point to a writable `u64`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_surface_attach(
    layer: *mut c_void,
    width_px: u32,
    height_px: u32,
    scale: f64,
    out_surface_id: *mut u64,
) -> i32 {
    if layer.is_null() || out_surface_id.is_null() {
        return code::ERR_INVALID_ARGUMENT;
    }

    let mut guard = match GPU.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    let Some(context) = guard.as_mut() else {
        return code::ERR_NOT_INITIALIZED;
    };

    let config = SurfaceConfig::new(width_px, height_px, scale);
    match context.attach_surface(SurfaceTarget::CoreAnimationLayer(layer), config) {
        Ok(surface_id) => {
            // SAFETY: the caller guarantees `out_surface_id` is writable (documented above).
            unsafe { out_surface_id.write(surface_id.0) };
            code::OK
        }
        Err(error) => {
            eprintln!("aris-gpu: attach failed: {error}");
            code::ERR_GPU_UNAVAILABLE
        }
    }
}

/// Updates the surface size/scale (window resize, screen change).
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_surface_resize(
    surface_id: u64,
    width_px: u32,
    height_px: u32,
    scale: f64,
) -> i32 {
    with_context(|context| {
        context.resize_surface(
            SurfaceId(surface_id),
            SurfaceConfig::new(width_px, height_px, scale),
        )
    })
}

/// Renders one frame into the surface and presents it.
///
/// `stats` may be null; when it is not, it receives the frame report described by
/// [`ArisFrameStats`] (this is how the host verifies that pixels actually arrived).
///
/// # Safety
///
/// `stats` must be null or point to a writable [`ArisFrameStats`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_surface_render(
    surface_id: u64,
    stats: *mut ArisFrameStats,
) -> i32 {
    let mut report = None;
    let result = with_context(|context| {
        // Dark neutral clear colour: the spike triangle is unmistakable against it.
        let frame = context.render_frame(SurfaceId(surface_id), [0.09, 0.09, 0.11, 1.0])?;
        // First frame and then roughly every ten seconds: enough to verify from a
        // log without drowning the console at display rate.
        if frame.surface_frame_index <= 4 || frame.surface_frame_index % 600 == 0 {
            let pixel = frame.center_pixel_bgra.unwrap_or([0, 0, 0, 0]);
            println!(
                "aris-gpu: surface {} frame {} — {}×{} px, sRGB={}, presented={}, centre=#{:02X}{:02X}{:02X}",
                surface_id,
                frame.frame_index,
                frame.width,
                frame.height,
                frame.format_is_srgb,
                frame.presented,
                pixel[2],
                pixel[1],
                pixel[0]
            );
        }
        report = Some(frame);
        Ok(())
    });

    // SAFETY: the contract of the exported function requires a writable `stats`.
    unsafe { write_stats(result, report, stats) };
    result
}

/// Copies a frame report into the caller's struct (a no-op for null pointers).
///
/// # Safety
///
/// `stats` must be null or writable.
unsafe fn write_stats(
    result: i32,
    report: Option<aris_reader_gpu::FrameReport>,
    stats: *mut ArisFrameStats,
) {
    if result != code::OK {
        return;
    }
    let Some(frame) = report else { return };
    if stats.is_null() {
        return;
    }

    let [blue, green, red, alpha] = frame.center_pixel_bgra.unwrap_or([0, 0, 0, 0]);
    // Packed as 0xAARRGGBB, which is what the Swift side decodes.
    let center_argb =
        u32::from(alpha) << 24 | u32::from(red) << 16 | u32::from(green) << 8 | u32::from(blue);

    // SAFETY: the caller guarantees `stats` is null or writable (documented above).
    unsafe {
        stats.write(ArisFrameStats {
            presented: u32::from(frame.presented),
            width: frame.width,
            height: frame.height,
            srgb: u32::from(frame.format_is_srgb),
            center_bgra: center_argb,
            elapsed_us: frame.elapsed_us.min(u64::from(u32::MAX)) as u32,
            frame_index: frame.frame_index,
            surface_frame_index: frame.surface_frame_index,
        });
    }
}

/// Unregisters a surface (only after this may Swift release the corresponding `CAMetalLayer`).
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_surface_detach(surface_id: u64) -> i32 {
    with_context(|context| context.detach_surface(SurfaceId(surface_id)))
}

/// Uploads a page bitmap (BGRA, sRGB, tightly packed) as a GPU texture.
///
/// # Safety
///
/// `pixels` must point to at least `width * height * 4` readable bytes and
/// `out_texture_id` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_gpu_upload_texture(
    width: u32,
    height: u32,
    pixels: *const u8,
    len: usize,
    out_texture_id: *mut u64,
) -> i32 {
    if pixels.is_null() || out_texture_id.is_null() {
        return code::ERR_INVALID_ARGUMENT;
    }
    let expected = (width as usize) * (height as usize) * 4;
    if len < expected {
        return code::ERR_INVALID_ARGUMENT;
    }
    // SAFETY: the caller guarantees `pixels` covers `expected` bytes (documented above).
    let bytes = unsafe { std::slice::from_raw_parts(pixels, expected) };

    let mut texture_id = 0u64;
    let result = with_context(|context| {
        let id = context.upload_page_texture(width, height, bytes)?;
        texture_id = id.0;
        Ok(())
    });
    if result == code::OK {
        // SAFETY: the caller guarantees `out_texture_id` is writable (documented above).
        unsafe { out_texture_id.write(texture_id) };
    }
    result
}

/// Releases a texture uploaded by [`aris_reader_gpu_upload_texture`].
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_gpu_release_texture(texture_id: u64) -> i32 {
    with_context(|context| context.release_texture(aris_reader_gpu::TextureId(texture_id)))
}

/// Draws an uploaded texture into the surface at `[x, y, width, height]` in physical
/// pixels and presents the frame. `stats` may be null.
///
/// # Safety
///
/// `stats` must be null or point to a writable [`ArisFrameStats`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_surface_draw_page(
    surface_id: u64,
    texture_id: u64,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    stats: *mut ArisFrameStats,
) -> i32 {
    let mut report = None;
    let result = with_context(|context| {
        let frame = context.render_page(
            SurfaceId(surface_id),
            aris_reader_gpu::TextureId(texture_id),
            [x, y, width, height],
            // Neutral reading background; pages are drawn on top of it.
            [0.13, 0.13, 0.15, 1.0],
        )?;
        if frame.surface_frame_index <= 4 || frame.surface_frame_index % 600 == 0 {
            println!(
                "aris-gpu: surface {} page frame {} — {}×{} px, presented={}, quad=({:.0},{:.0} {:.0}×{:.0})",
                surface_id,
                frame.surface_frame_index,
                frame.width,
                frame.height,
                frame.presented,
                x,
                y,
                width,
                height
            );
        }
        report = Some(frame);
        Ok(())
    });

    // SAFETY: the contract of the exported function requires a writable `stats`.
    unsafe { write_stats(result, report, stats) };
    result
}

/// Draws several uploaded textures into **one frame** at device-pixel rectangles.
///
/// Continuous scrolling needs this: every visible page goes into a single frame instead
/// of one acquire/present per page.
///
/// # Safety
///
/// `texture_ids` must point to `count` readable `u64`s, `rects` to `count * 4` readable
/// `f32`s (`[x, y, width, height]` each) and `stats` must be null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_surface_draw_pages(
    surface_id: u64,
    texture_ids: *const u64,
    rects: *const f32,
    count: usize,
    stats: *mut ArisFrameStats,
) -> i32 {
    if count == 0 || texture_ids.is_null() || rects.is_null() {
        return code::ERR_INVALID_ARGUMENT;
    }

    // SAFETY: the caller guarantees both arrays cover `count` elements (documented above).
    let ids = unsafe { std::slice::from_raw_parts(texture_ids, count) };
    let coordinates = unsafe { std::slice::from_raw_parts(rects, count * 4) };

    let mut draws = Vec::with_capacity(count);
    for (index, id) in ids.iter().enumerate() {
        let rect = &coordinates[index * 4..index * 4 + 4];
        draws.push((
            aris_reader_gpu::TextureId(*id),
            [rect[0], rect[1], rect[2], rect[3]],
        ));
    }

    let mut report = None;
    let result = with_context(|context| {
        let frame = context.render_pages(
            SurfaceId(surface_id),
            &draws,
            // Neutral reading background; pages are drawn on top of it.
            [0.13, 0.13, 0.15, 1.0],
        )?;
        if frame.surface_frame_index <= 4 || frame.surface_frame_index % 600 == 0 {
            let summary: Vec<String> = draws
                .iter()
                .map(|(_, rect)| {
                    format!(
                        "({:.0},{:.0} {:.0}×{:.0})",
                        rect[0], rect[1], rect[2], rect[3]
                    )
                })
                .collect();
            println!(
                "aris-gpu: surface {} page frame {} — {} quads in {:.1} ms: {}",
                surface_id,
                frame.surface_frame_index,
                draws.len(),
                frame.elapsed_us as f64 / 1000.0,
                summary.join(" ")
            );
        }
        report = Some(frame);
        Ok(())
    });

    // SAFETY: the contract of the exported function requires a writable `stats`.
    unsafe { write_stats(result, report, stats) };
    result
}

/// Renders the spike content offscreen and copies it into `out_rgba`.
///
/// This is the window-less self-test: it exercises device, shader, render pass and
/// readback, so a host (or CI) can verify the GPU path without a visible window.
///
/// # Safety
///
/// `out_rgba` must point to at least `size * size * 4` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_gpu_offscreen_probe(
    size: u32,
    out_rgba: *mut u8,
    len: usize,
) -> i32 {
    if out_rgba.is_null() || size == 0 {
        return code::ERR_INVALID_ARGUMENT;
    }
    let needed = (size as usize) * (size as usize) * 4;
    if len < needed {
        return code::ERR_INVALID_ARGUMENT;
    }

    with_context(|context| {
        let pixels = context.offscreen_probe(size, [0.0, 0.0, 0.0, 1.0])?;
        // SAFETY: the caller guarantees `out_rgba` has room for `needed` bytes.
        unsafe {
            std::ptr::copy_nonoverlapping(pixels.as_ptr(), out_rgba, needed);
        }
        Ok(())
    })
}

/// Shuts down the GPU (releases the device and all surfaces; call before the process exits).
#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_gpu_shutdown() -> i32 {
    let mut guard = match GPU.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    *guard = None;
    code::OK
}

/// Runs `body` against the live GPU context and maps errors to C ABI codes.
fn with_context<F>(body: F) -> i32
where
    F: FnOnce(&mut GpuContext) -> aris_reader_core::Result<()>,
{
    let mut guard = match GPU.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    let Some(context) = guard.as_mut() else {
        return code::ERR_NOT_INITIALIZED;
    };
    match body(context) {
        Ok(()) => code::OK,
        Err(error) => {
            use aris_reader_core::ErrorCode;
            eprintln!("aris-gpu: {error}");
            match error.code {
                ErrorCode::InvalidArgument | ErrorCode::NotReady => code::ERR_INVALID_ARGUMENT,
                ErrorCode::GpuUnavailable | ErrorCode::BackendUnavailable => {
                    code::ERR_GPU_UNAVAILABLE
                }
                ErrorCode::GpuDeviceLost => code::ERR_GPU_DEVICE_LOST,
                ErrorCode::UnsupportedFeature => code::ERR_NOT_IMPLEMENTED,
                _ => code::ERR_INTERNAL,
            }
        }
    }
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
        let mut surface_id = 0u64;
        // SAFETY: a null layer pointer is passed in, so the function returns an error code
        // before dereferencing anything; `surface_id` is a valid local.
        let rc = unsafe {
            aris_reader_surface_attach(std::ptr::null_mut(), 100, 100, 2.0, &mut surface_id)
        };
        assert_eq!(rc, code::ERR_INVALID_ARGUMENT);
    }

    #[test]
    fn render_without_initialization_reports_not_initialized() {
        // The GPU is not initialized in this test process (init is only called by the host).
        let rc = aris_reader_surface_resize(1, 100, 100, 2.0);
        assert!(
            rc == code::ERR_NOT_INITIALIZED || rc == code::ERR_INVALID_ARGUMENT,
            "unexpected code {rc}"
        );
    }

    /// End-to-end GPU self-test through the C ABI, mirroring what the host does.
    #[test]
    fn offscreen_probe_through_the_c_abi() {
        if aris_reader_gpu_init(0) != code::OK {
            eprintln!("skipping: no GPU available");
            return;
        }

        let size = 32usize;
        let mut pixels = vec![0u8; size * size * 4];
        // SAFETY: `pixels` is a valid buffer of at least size*size*4 bytes.
        let rc = unsafe {
            aris_reader_gpu_offscreen_probe(size as u32, pixels.as_mut_ptr(), pixels.len())
        };
        assert_eq!(rc, code::OK, "offscreen probe failed");

        let center = ((size / 2) * size + (size / 2)) * 4;
        let (r, g, b) = (pixels[center], pixels[center + 1], pixels[center + 2]);
        assert!(
            r > 200 && g < 200 && b < 120,
            "triangle not visible at centre: {r},{g},{b}"
        );

        assert_eq!(aris_reader_gpu_shutdown(), code::OK);
    }
}
