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
//! # Device ownership (M0 T0.4 spike result)
//!
//! `docs/adr/0003` listed three strategies; the spike settled on the simplest one:
//!
//! | Option | Result |
//! | --- | --- |
//! | **B. Both sides use the process-wide default device** ✅ chosen | wgpu's Metal backend and AppKit's `CAMetalLayer` both take the device returned by `MTLCreateSystemDefaultDevice()`, so they are the *same* `MTLDevice` and textures interoperate. No private API, no hand-off call. |
//! | A. Rust owns the device and hands `MTLDevice` to Swift | Not reachable: `Device::as_hal` is gated behind wgpu's internal `cfg(wgpu_core)` (verified by reading wgpu 30.0.1's source). |
//! | C. Offscreen + IOSurface fallback | Kept as a documented fallback; not needed. |

pub mod context;

pub use context::{FrameReport, GpuContext, SPIKE_TRIANGLE_RGBA};

use aris_reader_core::{DocId, PageIndex, Rect, Size};
use std::ffi::c_void;

/// GPU surface identifier (allocated by this crate; Swift only ever holds this opaque integer).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SurfaceId(pub u64);

/// Layer index within the texture array (used by the tile cache).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TextureLayer(pub u32);

/// Surface colour space (avoids a double conversion; `docs/03-rendering.md` §7).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorSpace {
    Srgb,
    /// Used when the display is P3; the system performs the final conversion.
    DisplayP3,
}

/// Size and colour configuration of a surface.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SurfaceConfig {
    /// Width in physical pixels.
    pub width_px: u32,
    /// Height in physical pixels.
    pub height_px: u32,
    /// Backing scale factor (2.0 on Retina).
    pub scale: f64,
    pub color_space: ColorSpace,
}

impl SurfaceConfig {
    pub fn new(width_px: u32, height_px: u32, scale: f64) -> Self {
        Self {
            width_px: width_px.max(1),
            height_px: height_px.max(1),
            scale,
            color_space: ColorSpace::Srgb,
        }
    }
}

/// Native window/layer target.
///
/// # Safety
///
/// The raw pointer in each variant is owned by the thread that created it (normally the UI main
/// thread) and must:
///
/// 1. stay alive until the corresponding surface is destroyed ([`GpuContext::detach_surface`]) —
///    this is an explicit contract of wgpu's Metal backend, see `docs/05-ffi.md` §6;
/// 2. only ever be converted into a [`SurfaceId`] via [`GpuContext::attach_surface`] before being
///    referenced from another thread.
///
/// Hence this type intentionally does **not** implement `Send`/`Sync`.
#[derive(Clone, Copy, Debug)]
pub enum SurfaceTarget {
    /// macOS: a `CAMetalLayer` pointer (`SurfaceTargetUnsafe::CoreAnimationLayer`).
    CoreAnimationLayer(*mut c_void),
    /// Fallback: an IOSurface id (offscreen rendering handed to the system compositor).
    Iosurface(u32),
    /// Windows: `HWND` (M6).
    Win32Hwnd(*mut c_void),
    /// Linux: `wl_surface` or an X11 window (M6).
    WaylandSurface(*mut c_void),
}

/// Commands posted to the GPU thread.
#[derive(Clone, Copy, Debug)]
pub enum CompositorCommand {
    /// Upload one tile into a layer of the texture array.
    UploadTile {
        layer: TextureLayer,
        size: Size,
        bytes: usize,
    },
    /// Draw one frame.
    DrawFrame { epoch: u64 },
    /// Update a surface viewport (device pixels).
    SetViewport { surface: SurfaceId, viewport: Rect },
    /// Switch which document/page a surface displays.
    SetContent {
        surface: SurfaceId,
        doc: DocId,
        page: PageIndex,
    },
    /// Destroy a surface (only after this may the `CAMetalLayer` be released).
    DetachSurface(SurfaceId),
    /// Rebuild the device after a loss (drops every cached texture).
    RecreateDevice,
}

/// Capacity plan for the tile texture array (`docs/03-rendering.md` §6).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextureArrayPlan {
    pub tile_size: u32,
    pub layers: u32,
    pub mip_levels: u32,
}

impl TextureArrayPlan {
    /// 512² × 2048 layers ≈ 2 GB ceiling; the cache budget decides what is resident.
    pub const DEFAULT: Self = Self {
        tile_size: 512,
        layers: 2048,
        mip_levels: 4,
    };

    pub fn bytes_per_layer(&self) -> u64 {
        let pixels = u64::from(self.tile_size) * u64::from(self.tile_size);
        // Including the mip chain: about 4/3 of the base level.
        pixels * 4 * 4 / 3
    }
}
