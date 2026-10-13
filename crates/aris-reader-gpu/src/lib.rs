//! GPU abstraction layer: wgpu context, surface management, tile compositing.
//!
//! **This is the only engine crate allowed to contain platform/GPU details** (see `docs/adr/0001`).
//!
//! # Threading model (hard rules, `docs/02-architecture.md` §3)
//!
//! - `wgpu::Device/Queue/Surface` and all textures are created/destroyed **only on the GPU submit thread**;
//! - The UI thread only submits [`CompositorCommand`]s;
//! - [`SurfaceTarget`] contains raw pointers and **does not implement `Send`**: it can only be turned into
//!   [`SurfaceId`] on the thread that created it, after which it is always referenced across threads by `SurfaceId`.
//!
//! # Device ownership (`docs/adr/0003`, settled in M0 T0.4)
//!
//! | Option | Status |
//! | --- | --- |
//! | A. Rust owns the device (`aris_reader_gpu_metal_device_ptr` → Swift creates the layer → pointer handed back) | Preferred, pending validation of `Device::as_hal` |
//! | B. Swift owns the device | No publicly supported path today |
//! | C. Offscreen + IOSurface fallback | Alternative |

use aris_reader_core::{Rect, Size};
use std::ffi::c_void;

/// GPU surface identifier (allocated by this crate; Swift only ever holds this opaque integer).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SurfaceId(pub u64);

/// Layer index within the texture array (used by the tile cache).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TextureLayer(pub u32);

/// Surface color space (avoids a double conversion and the resulting color shift; see `docs/03-rendering.md` §7).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorSpace {
    Srgb,
    /// Used when the display is P3; the system performs the final conversion.
    DisplayP3,
}

/// Size and color configuration of a surface.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SurfaceConfig {
    /// Width in physical pixels.
    pub width_px: u32,
    /// Height in physical pixels.
    pub height_px: u32,
    /// Scale factor (2.0 on a typical Retina display).
    pub scale: f64,
    pub color_space: ColorSpace,
}

/// Native window/layer target.
///
/// # Safety
///
/// The raw pointer held by each variant is **owned by the thread that created it (usually the UI main
/// thread)** and must:
///
/// 1. stay alive until the corresponding surface is destroyed ([`CompositorCommand::DetachSurface`])
///    (this is an explicit contract of the wgpu Metal backend, see `docs/05-ffi.md` §6);
/// 2. only ever be converted into a [`SurfaceId`] via [`GpuContext::attach_surface`] before being used
///    across threads.
///
/// This type therefore intentionally **does not implement `Send`/`Sync`**.
#[derive(Clone, Copy, Debug)]
pub enum SurfaceTarget {
    /// macOS: `CAMetalLayer` pointer (`SurfaceTargetUnsafe::CoreAnimationLayer`).
    CoreAnimationLayer(*mut c_void),
    /// Fallback option C: IOSurface ID (rendered offscreen, then handed to the system for compositing).
    Iosurface(u32),
    /// Windows: `HWND` (M6).
    Win32Hwnd(*mut c_void),
    /// Linux: `wl_surface` or X11 `Window` (M6).
    WaylandSurface(*mut c_void),
}

/// Command submitted to the GPU thread.
#[derive(Clone, Copy, Debug)]
pub enum CompositorCommand {
    /// Upload one tile into the given layer of the texture array (the CPU side keeps the data alive until the command completes).
    UploadTile {
        layer: TextureLayer,
        size: Size,
        bytes: usize,
    },
    /// Draw one frame.
    DrawFrame { epoch: u64 },
    /// Update the viewport of one surface (in device pixels).
    SetViewport { surface: SurfaceId, viewport: Rect },
    /// Switch which document/page combination a surface displays.
    SetContent {
        surface: SurfaceId,
        doc: aris_reader_core::DocId,
        page: aris_reader_core::PageIndex,
    },
    /// Destroy a surface (only after this may the corresponding `CAMetalLayer` be released).
    DetachSurface(SurfaceId),
    /// Rebuild after GPU device loss (drops all texture caches and re-attaches every surface).
    RecreateDevice,
}

/// GPU context. A process-wide singleton, created and owned by `aris-reader-ffi`.
///
/// TODO(T0.4/T0.5/T1.7): will own `wgpu::Instance/Adapter/Device/Queue`, the texture array,
/// the compositing pipeline and the surface table.
pub struct GpuContext {
    _private: (),
}

impl GpuContext {
    /// Initialize the GPU (option A: Rust creates the device).
    pub fn new(_validation: bool) -> aris_reader_core::Result<Self> {
        Err(aris_reader_core::ArisError::not_implemented(
            "GpuContext::new (T0.4 spike)",
        ))
    }

    /// Option A: lend the internal `MTLDevice` as a raw pointer so Swift can create the `CAMetalLayer`.
    ///
    /// The returned pointer is valid only as a **borrow** (ownership stays with `GpuContext`, and it stays valid for as long as `GpuContext` lives).
    pub fn metal_device_ptr(&self) -> *mut c_void {
        std::ptr::null_mut()
    }

    /// Register a surface; returns an opaque id.
    pub fn attach_surface(
        &mut self,
        _target: SurfaceTarget,
        _config: SurfaceConfig,
    ) -> aris_reader_core::Result<SurfaceId> {
        Err(aris_reader_core::ArisError::not_implemented(
            "GpuContext::attach_surface (T0.4 spike)",
        ))
    }

    /// Update the surface size/scale.
    pub fn resize_surface(
        &mut self,
        _id: SurfaceId,
        _config: SurfaceConfig,
    ) -> aris_reader_core::Result<()> {
        Ok(())
    }

    /// Submit a command to the GPU thread.
    pub fn submit(&self, _command: CompositorCommand) {}

    /// Wait until the GPU thread has processed every submitted command (used only by shutdown and tests).
    pub fn flush(&self) {}
}

/// Capacity planning for the texture array (`docs/03-rendering.md` §6).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextureArrayPlan {
    pub tile_size: u32,
    pub layers: u32,
    pub mip_levels: u32,
}

impl TextureArrayPlan {
    /// 512² × 2048 layers ≈ 2 GB upper bound; residency is actually governed by the cache budget (layers allocated on demand).
    pub const DEFAULT: Self = Self {
        tile_size: 512,
        layers: 2048,
        mip_levels: 4,
    };

    pub fn bytes_per_layer(&self) -> u64 {
        let px = self.tile_size as u64 * self.tile_size as u64;
        // Including the mip chain: about 4/3
        px * 4 * 4 / 3
    }
}
