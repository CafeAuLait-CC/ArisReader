//! wgpu context: device creation, surface attachment and the M0 render path.
//!
//! # What this module is (and is not)
//!
//! It is the **M0 spike** renderer: a single coloured triangle drawn with a
//! runtime-compiled WGSL shader. It exists to prove the hard part — a wgpu device
//! drawing into an AppKit-owned `CAMetalLayer` — and it deliberately has no tile
//! compositor yet (that is T1.7).
//!
//! The triangle pipeline is also the vehicle for the headless verification in
//! [`GpuContext::offscreen_probe`], which renders the same content into an
//! offscreen texture and reads the pixels back, so the GPU path can be tested
//! without a window (and therefore in CI).

use crate::{
    ColorSpace, CompositorCommand, SurfaceConfig, SurfaceId, SurfaceTarget, TextureArrayPlan,
};
use aris_reader_core::{ArisError, ErrorCode, Result};
use std::collections::HashMap;
use std::ffi::c_void;
use std::time::Instant;

/// The spike shader: a single triangle, no vertex buffer, no bindings.
///
/// `vertex_index` drives the geometry so that the pipeline cannot fail because of
/// buffer layout mistakes — the point of the spike is the *surface*, not the mesh.
const SPIKE_SHADER: &str = r#"
@vertex
fn vs_main(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
    var positions = array<vec2<f32>, 3>(
        vec2<f32>( 0.0,  0.6),
        vec2<f32>(-0.6, -0.4),
        vec2<f32>( 0.6, -0.4),
    );
    return vec4<f32>(positions[index], 0.0, 1.0);
}

@fragment
fn fs_main() -> @location(0) vec4<f32> {
    // ArisReader accent orange, so the frame is unmistakable on screen.
    return vec4<f32>(0.95, 0.35, 0.15, 1.0);
}
"#;

/// Colour of the spike triangle in linear-ish sRGB, used by the verification.
pub const SPIKE_TRIANGLE_RGBA: [u8; 4] = [242, 89, 38, 255];

/// What happened during one rendered frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FrameReport {
    pub surface_id: SurfaceId,
    pub width: u32,
    pub height: u32,
    /// Surface texture format as reported by wgpu, e.g. `Bgra8UnormSrgb`.
    pub format_is_srgb: bool,
    pub color_space: ColorSpace,
    /// Whether the frame was handed to the window server.
    pub presented: bool,
    /// Centre pixel read back from the surface texture (BGRA), when the surface
    /// allows copying; `None` on backends that do not expose `COPY_SRC`.
    pub center_pixel_bgra: Option<[u8; 4]>,
    pub elapsed_us: u64,
    /// Frames rendered since the context was created (all surfaces).
    pub frame_index: u64,
    /// Frames rendered by this surface.
    pub surface_frame_index: u64,
}

struct SurfaceEntry {
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    settings: SurfaceConfig,
    frame_index: u64,
}

/// GPU context: process-wide device plus a table of attached surfaces.
///
/// Owned by `aris-reader-ffi`; every method must be called from the GPU thread
/// (for the spike the FFI layer serialises calls behind a mutex).
pub struct GpuContext {
    instance: wgpu::Instance,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    surfaces: HashMap<SurfaceId, SurfaceEntry>,
    /// One pipeline per target format; surfaces and the offscreen probe differ.
    pipelines: HashMap<wgpu::TextureFormat, wgpu::RenderPipeline>,
    shader: wgpu::ShaderModule,
    next_surface_id: u64,
    frames_rendered: u64,
}

impl GpuContext {
    /// Creates the instance, adapter, device and queue.
    ///
    /// `validation` enables wgpu's validation layer; the FFI layer turns it on for
    /// debug builds (see `ARIS_READER_GPU_VALIDATION`).
    pub fn new(validation: bool) -> Result<Self> {
        let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
        descriptor.backends = wgpu::Backends::METAL;
        descriptor.flags = if validation {
            wgpu::InstanceFlags::debugging()
        } else {
            wgpu::InstanceFlags::empty()
        };
        let instance = wgpu::Instance::new(descriptor);

        let adapter = pollster_block(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            force_fallback_adapter: false,
            compatible_surface: None,
            apply_limit_buckets: false,
        }))
        .map_err(|error| {
            ArisError::new(ErrorCode::GpuUnavailable, "no suitable GPU adapter")
                .with_detail(error.to_string())
        })?;

        let (device, queue) = pollster_block(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("aris-reader-device"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::default(),
            memory_hints: wgpu::MemoryHints::default(),
            trace: wgpu::Trace::Off,
            experimental_features: Default::default(),
        }))
        .map_err(|error| {
            ArisError::new(ErrorCode::GpuUnavailable, "could not create the GPU device")
                .with_detail(error.to_string())
        })?;

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("aris-reader-spike-shader"),
            source: wgpu::ShaderSource::Wgsl(SPIKE_SHADER.into()),
        });

        Ok(Self {
            instance,
            adapter,
            device,
            queue,
            surfaces: HashMap::new(),
            pipelines: HashMap::new(),
            shader,
            next_surface_id: 1,
            frames_rendered: 0,
        })
    }

    /// A human-readable description of the adapter (for logs and `--version`).
    pub fn adapter_description(&self) -> String {
        let info = self.adapter.get_info();
        format!("{} ({:?}, {:?})", info.name, info.backend, info.device_type)
    }

    pub fn frames_rendered(&self) -> u64 {
        self.frames_rendered
    }

    pub fn surface_count(&self) -> usize {
        self.surfaces.len()
    }

    /// Registers a native layer as a render target and configures it.
    ///
    /// The only `unsafe` in this crate: wgpu cannot verify the raw layer pointer, so the
    /// contract documented on [`SurfaceTarget`] is ours to uphold.
    #[allow(unsafe_code)]
    pub fn attach_surface(
        &mut self,
        target: SurfaceTarget,
        config: SurfaceConfig,
    ) -> Result<SurfaceId> {
        let surface = match target {
            SurfaceTarget::CoreAnimationLayer(pointer) => {
                if pointer.is_null() {
                    return Err(ArisError::new(
                        ErrorCode::InvalidArgument,
                        "CAMetalLayer pointer is null",
                    ));
                }
                // SAFETY: the caller guarantees (documented on `SurfaceTarget`) that
                // the layer stays alive until `detach_surface`, and that it is a valid
                // `CAMetalLayer`. `'static` is the lifetime wgpu requires for unsafe
                // surface creation; the FFI layer enforces it by keeping the layer's
                // owner (the NSView) alive for the whole surface lifetime.
                unsafe {
                    self.instance.create_surface_unsafe(
                        wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(pointer),
                    )
                }
            }
            other => {
                return Err(ArisError::not_implemented(&format!(
                    "surface target {other:?} (Windows/Linux land in M6)"
                )));
            }
        }
        .map_err(|error| {
            ArisError::new(ErrorCode::GpuUnavailable, "could not create a wgpu surface")
                .with_detail(error.to_string())
        })?;

        let capabilities = surface.get_capabilities(&self.adapter);
        let format = capabilities
            .formats
            .iter()
            .copied()
            .find(|format| format.is_srgb())
            .unwrap_or(capabilities.formats[0]);

        // COPY_SRC is what lets the spike read a pixel back from the drawable and
        // prove the frame really landed; surfaces that do not support it simply skip
        // the verification (`framebufferOnly` must be false on the CAMetalLayer).
        let mut usage = wgpu::TextureUsages::RENDER_ATTACHMENT;
        if capabilities.usages.contains(wgpu::TextureUsages::COPY_SRC) {
            usage |= wgpu::TextureUsages::COPY_SRC;
        }

        let surface_config = wgpu::SurfaceConfiguration {
            usage,
            format,
            width: config.width_px,
            height: config.height_px,
            present_mode: wgpu::PresentMode::Fifo,
            desired_maximum_frame_latency: 2,
            alpha_mode: capabilities.alpha_modes[0],
            view_formats: vec![],
            // srgb unless the display is P3; see docs/03-rendering.md §7.
            color_space: wgpu::SurfaceColorSpace::Srgb,
        };
        surface.configure(&self.device, &surface_config);

        self.ensure_pipeline(format)?;

        let id = SurfaceId(self.next_surface_id);
        self.next_surface_id += 1;
        self.surfaces.insert(
            id,
            SurfaceEntry {
                surface,
                config: surface_config,
                settings: config,
                frame_index: 0,
            },
        );

        println!(
            "aris-gpu: attached surface {} ({}×{} px, {:?}, scale {:.1}, copy_src={})",
            id.0,
            config.width_px,
            config.height_px,
            format,
            config.scale,
            capabilities.usages.contains(wgpu::TextureUsages::COPY_SRC)
        );
        Ok(id)
    }

    /// Updates the size/scale of an attached surface.
    pub fn resize_surface(&mut self, id: SurfaceId, config: SurfaceConfig) -> Result<()> {
        // Field-level borrows: `self.surfaces` mutably, `self.device` immutably.
        let entry = self
            .surfaces
            .get_mut(&id)
            .ok_or_else(|| unknown_surface(id))?;
        entry.config.width = config.width_px;
        entry.config.height = config.height_px;
        entry.settings = config;
        entry.surface.configure(&self.device, &entry.config);
        Ok(())
    }

    /// Renders one frame (clear + triangle) into the surface and presents it.
    pub fn render_frame(&mut self, id: SurfaceId, clear: [f64; 4]) -> Result<FrameReport> {
        let started = Instant::now();

        // `get` (not `get_mut`) keeps the borrow immutable, so the device may be used
        // below without splitting `self`. `SurfaceTexture` is owned, so the borrow of
        // the surface table ends as soon as the frame is in hand.
        let entry = self.surfaces.get(&id).ok_or_else(|| unknown_surface(id))?;
        let format = entry.config.format;
        let width = entry.config.width;
        let height = entry.config.height;
        let settings = entry.settings;

        let frame = match entry.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(frame)
            | wgpu::CurrentSurfaceTexture::Suboptimal(frame) => frame,
            wgpu::CurrentSurfaceTexture::Timeout => {
                return Err(
                    ArisError::new(ErrorCode::RenderFailed, "timed out acquiring a frame")
                        .with_severity(aris_reader_core::Severity::Recoverable),
                );
            }
            wgpu::CurrentSurfaceTexture::Occluded => {
                // Perfectly normal: the window is hidden or minimised.
                return Ok(FrameReport {
                    surface_id: id,
                    width,
                    height,
                    format_is_srgb: format.is_srgb(),
                    color_space: settings.color_space,
                    presented: false,
                    center_pixel_bgra: None,
                    elapsed_us: started.elapsed().as_micros() as u64,
                    frame_index: self.frames_rendered,
                    surface_frame_index: entry.frame_index,
                });
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                entry.surface.configure(&self.device, &entry.config);
                return Err(ArisError::new(
                    ErrorCode::GpuDeviceLost,
                    "surface was lost and has been reconfigured",
                ));
            }
            // `CurrentSurfaceTexture` is non-exhaustive in practice; never fall through
            // silently — an unknown status would mean a bogus frame.
            other => {
                return Err(ArisError::new(
                    ErrorCode::RenderFailed,
                    "could not acquire a surface texture",
                )
                .with_detail(format!("{other:?}")));
            }
        };

        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        let can_read_back = frame
            .texture
            .usage()
            .contains(wgpu::TextureUsages::COPY_SRC);
        let readback = can_read_back.then(|| {
            self.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("surface-readback"),
                size: 256,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            })
        });

        self.ensure_pipeline(format)?;
        let pipeline = self.pipeline(format).ok_or_else(|| {
            ArisError::new(ErrorCode::Internal, "pipeline missing after creation")
        })?;
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("aris-frame"),
            });
        {
            let color_attachment = wgpu::RenderPassColorAttachment {
                view: &view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color {
                        r: clear[0],
                        g: clear[1],
                        b: clear[2],
                        a: clear[3],
                    }),
                    store: wgpu::StoreOp::Store,
                },
            };
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("aris-frame-pass"),
                color_attachments: &[Some(color_attachment)],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(pipeline);
            pass.draw(0..3, 0..1);
        }

        if let Some(buffer) = &readback {
            // One pixel in the middle of the frame; rows are 256-byte aligned, which a
            // single 4-byte texel satisfies trivially.
            encoder.copy_texture_to_buffer(
                wgpu::TexelCopyTextureInfo {
                    texture: &frame.texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d {
                        x: width / 2,
                        y: height / 2,
                        z: 0,
                    },
                    aspect: wgpu::TextureAspect::All,
                },
                wgpu::TexelCopyBufferInfo {
                    buffer,
                    layout: wgpu::TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(256),
                        rows_per_image: Some(1),
                    },
                },
                wgpu::Extent3d {
                    width: 1,
                    height: 1,
                    depth_or_array_layers: 1,
                },
            );
        }

        self.queue.submit(Some(encoder.finish()));
        self.queue.present(frame);

        let center_pixel = readback.and_then(|buffer| self.read_back_pixel(&buffer));

        self.frames_rendered += 1;
        let surface_frame_index = {
            let entry = self
                .surfaces
                .get_mut(&id)
                .ok_or_else(|| unknown_surface(id))?;
            entry.frame_index += 1;
            entry.frame_index
        };

        Ok(FrameReport {
            surface_id: id,
            width,
            height,
            format_is_srgb: format.is_srgb(),
            color_space: settings.color_space,
            presented: true,
            center_pixel_bgra: center_pixel,
            elapsed_us: started.elapsed().as_micros() as u64,
            frame_index: self.frames_rendered,
            surface_frame_index,
        })
    }

    /// Renders the spike content into an offscreen texture and reads it back.
    ///
    /// This is the window-less verification path: it exercises device creation,
    /// shader compilation, the render pass and the readback, so the GPU pipeline can
    /// be checked on any machine (including CI) without a `CAMetalLayer`.
    pub fn offscreen_probe(&mut self, size: u32, clear: [f64; 4]) -> Result<Vec<u8>> {
        let format = wgpu::TextureFormat::Rgba8UnormSrgb;
        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("offscreen-probe"),
            size: wgpu::Extent3d {
                width: size,
                height: size,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

        // bytes_per_row must be a multiple of 256 for buffer copies.
        let bytes_per_row = (size * 4).div_ceil(256) * 256;
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("offscreen-probe-readback"),
            size: u64::from(bytes_per_row) * u64::from(size),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });

        self.ensure_pipeline(format)?;
        let pipeline = self.pipeline(format).ok_or_else(|| {
            ArisError::new(ErrorCode::Internal, "pipeline missing after creation")
        })?;
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("probe"),
            });
        {
            let color_attachment = wgpu::RenderPassColorAttachment {
                view: &view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color {
                        r: clear[0],
                        g: clear[1],
                        b: clear[2],
                        a: clear[3],
                    }),
                    store: wgpu::StoreOp::Store,
                },
            };
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("probe-pass"),
                color_attachments: &[Some(color_attachment)],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(pipeline);
            pass.draw(0..3, 0..1);
        }
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(bytes_per_row),
                    rows_per_image: Some(size),
                },
            },
            wgpu::Extent3d {
                width: size,
                height: size,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit(Some(encoder.finish()));

        let slice = buffer.slice(..);
        slice.map_async(wgpu::MapMode::Read, |_| {});
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());

        let mut pixels = Vec::with_capacity((size * size * 4) as usize);
        {
            let data = slice
                .get_mapped_range()
                .expect("buffer is mapped after poll");
            for row in 0..size {
                let start = (row * bytes_per_row) as usize;
                pixels.extend_from_slice(&data[start..start + (size * 4) as usize]);
            }
        }
        buffer.unmap();
        Ok(pixels)
    }

    /// Destroys a surface. The native layer may only be released after this returns.
    pub fn detach_surface(&mut self, id: SurfaceId) -> Result<()> {
        self.surfaces
            .remove(&id)
            .map(|_| ())
            .ok_or_else(|| unknown_surface(id))
    }

    /// Posts a compositor command (the tile pipeline lands in T1.7).
    pub fn submit(&self, _command: CompositorCommand) {}

    /// Capacity plan used by the tile cache (T1.6/T1.7).
    pub fn texture_array_plan(&self) -> TextureArrayPlan {
        TextureArrayPlan::DEFAULT
    }

    /// Placeholder for the FFI layer's "hand the MTLDevice to Swift" call.
    ///
    /// Always null: the spike uses the process-wide default device on both sides
    /// (see the crate docs), which makes an explicit hand-off unnecessary.
    pub fn metal_device_ptr(&self) -> *mut c_void {
        std::ptr::null_mut()
    }

    fn ensure_pipeline(&mut self, format: wgpu::TextureFormat) -> Result<()> {
        if !self.pipelines.contains_key(&format) {
            let pipeline = self
                .device
                .create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                    label: Some("aris-spike-pipeline"),
                    layout: None,
                    vertex: wgpu::VertexState {
                        module: &self.shader,
                        entry_point: Some("vs_main"),
                        buffers: &[],
                        compilation_options: Default::default(),
                    },
                    fragment: Some(wgpu::FragmentState {
                        module: &self.shader,
                        entry_point: Some("fs_main"),
                        targets: &[Some(wgpu::ColorTargetState {
                            format,
                            blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                            write_mask: wgpu::ColorWrites::ALL,
                        })],
                        compilation_options: Default::default(),
                    }),
                    primitive: wgpu::PrimitiveState::default(),
                    depth_stencil: None,
                    multisample: wgpu::MultisampleState::default(),
                    multiview_mask: None,
                    cache: None,
                });
            self.pipelines.insert(format, pipeline);
        }
        Ok(())
    }

    /// Immutable access to a cached pipeline (call [`Self::ensure_pipeline`] first).
    fn pipeline(&self, format: wgpu::TextureFormat) -> Option<&wgpu::RenderPipeline> {
        self.pipelines.get(&format)
    }

    fn read_back_pixel(&self, buffer: &wgpu::Buffer) -> Option<[u8; 4]> {
        let slice = buffer.slice(..4);
        slice.map_async(wgpu::MapMode::Read, |_| {});
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
        let pixel = {
            let data = slice
                .get_mapped_range()
                .expect("buffer is mapped after poll");
            if data.len() < 4 {
                None
            } else {
                Some([data[0], data[1], data[2], data[3]])
            }
        };
        buffer.unmap();
        pixel
    }
}

fn unknown_surface(id: SurfaceId) -> ArisError {
    ArisError::new(
        ErrorCode::InvalidArgument,
        format!("surface {} is not attached", id.0),
    )
}

/// Minimal blocking executor for wgpu's future-returning calls.
///
/// wgpu's native backends complete immediately, so a full async runtime would be
/// dead weight; `pollster` is not pulled in to keep the dependency set small.
fn pollster_block<F: std::future::Future>(future: F) -> F::Output {
    use std::task::{Context, Poll, Waker};

    let mut future = Box::pin(future);
    // A no-op waker is sufficient because wgpu's native futures never park.
    let waker = Waker::noop();
    let mut context = Context::from_waker(waker);
    loop {
        match future.as_mut().poll(&mut context) {
            Poll::Ready(output) => return output,
            Poll::Pending => std::thread::yield_now(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Headless verification of the whole GPU path.
    ///
    /// Skips (with a message) when no Metal adapter is available, so the suite stays
    /// runnable on machines without a GPU.
    #[test]
    fn offscreen_probe_renders_the_spike_triangle() {
        let mut context = match GpuContext::new(false) {
            Ok(context) => context,
            Err(error) => {
                eprintln!("skipping: {error}");
                return;
            }
        };

        let size = 64u32;
        let pixels = context
            .offscreen_probe(size, [0.0, 0.0, 0.0, 1.0])
            .expect("offscreen probe");

        assert_eq!(pixels.len(), (size * size * 4) as usize);

        let center = ((size / 2) * size + (size / 2)) as usize * 4;
        let (r, g, b, a) = (
            pixels[center],
            pixels[center + 1],
            pixels[center + 2],
            pixels[center + 3],
        );

        // sRGB storage of the shader's linear (0.95, 0.35, 0.15) is brighter than the
        // raw byte values, so compare with a generous tolerance and require the
        // triangle to dominate the cleared background.
        assert_eq!(a, 255, "the probe frame is opaque");
        assert!(r > 200, "red channel should dominate the triangle, got {r}");
        assert!((100..190).contains(&g), "green channel unexpected: {g}");
        assert!(b < 120, "blue channel should be small, got {b}");
        assert!(r > b + 80, "the triangle must be visible, got {r},{g},{b}");

        // A corner stays at the clear colour (black), proving the geometry is drawn.
        let corner = pixels[0..4].to_vec();
        assert!(
            corner[0] < 40 && corner[1] < 40 && corner[2] < 40,
            "corner should be clear colour, got {corner:?}"
        );
    }

    #[test]
    fn adapter_description_is_populated() {
        let context = match GpuContext::new(false) {
            Ok(context) => context,
            Err(error) => {
                eprintln!("skipping: {error}");
                return;
            }
        };
        let description = context.adapter_description();
        assert!(!description.is_empty());
        eprintln!("adapter: {description}");
    }
}
