//! Vulkan device, swapchain and frame loop (bindings: vulkan-zig).
//!
//! Per frame: `beginFrame` waits for the frame slot, acquires a swapchain
//! image and starts its command buffer; the renderer records its passes
//! (`beginScenePass` renders 4x MSAA into shared targets and resolves into
//! the swapchain image; `snapshotScene` pauses it to copy what is drawn so
//! far into `scene_copy` for shaders to sample); `beginUiPass` draws on top
//! of the resolved image;
//! `endFrame` submits and presents, optionally copying the image back for a
//! screenshot first.
//!
//! Vulkan 1.3 core: dynamic rendering (no render pass objects) and
//! synchronization2. Entry points come from SDL's Vulkan loader, so nothing
//! links against libvulkan.
const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const c = @import("c");
const Allocator = std.mem.Allocator;

const Gpu = @This();

pub const api_version = vk.API_VERSION_1_3;
pub const frames_in_flight = 2;
pub const samples: vk.SampleCountFlags = .{ .@"4" = true };

const log = std.log.scoped(.vulkan);

gpa: Allocator,
window: *c.SDL_Window,
vkb: vk.BaseWrapper,
instance: vk.InstanceProxy,
dev: vk.DeviceProxy,
debug_messenger: vk.DebugUtilsMessengerEXT = .null,
surface: vk.SurfaceKHR,
pdev: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,
queue: vk.Queue,
queue_family: u32,
/// Timestamps are usable on the graphics queue (for `--profile`).
timestamps: bool,

swapchain: vk.SwapchainKHR = .null,
surface_format: vk.SurfaceFormatKHR = undefined,
extent: vk.Extent2D = .{ .width = 0, .height = 0 },
/// Swapchain images can be copied from (screenshots).
can_capture: bool = false,
images: []vk.Image = &.{},
views: []vk.ImageView = &.{},
/// Signalled when an image's commands finish; presentation waits on it.
/// One per swapchain image, as presentation holds it until the image returns.
render_done: []vk.Semaphore = &.{},

depth_format: vk.Format,
msaa_color: Image = .{},
depth: Image = .{},
/// Single-sampled copy of the scene so far, sampled by glass atoms (see
/// `snapshotScene`). Layout between uses: shader_read_only_optimal, once
/// the renderer has initialised it (`scene_copy_fresh`).
scene_copy: Image = .{},
/// Set when `scene_copy` is (re)created, still in the undefined layout.
scene_copy_fresh: bool = false,
/// The current scene pass stores its targets (see `beginScenePass`).
scene_resumable: bool = false,

command_pool: vk.CommandPool,
frames: [frames_in_flight]FrameSlot = undefined,
slot: usize = 0,

/// Host buffer for screenshots, created on first use.
readback: ?Buffer = null,

const FrameSlot = struct {
    cmd: vk.CommandBuffer,
    fence: vk.Fence,
    acquired: vk.Semaphore,
};

/// A device-local image with one view.
pub const Image = struct {
    image: vk.Image = .null,
    memory: vk.DeviceMemory = .null,
    view: vk.ImageView = .null,

    pub fn deinit(img: *Image, gpu: *const Gpu) void {
        if (img.view != .null) gpu.dev.destroyImageView(img.view, null);
        if (img.image != .null) gpu.dev.destroyImage(img.image, null);
        if (img.memory != .null) gpu.dev.freeMemory(img.memory, null);
        img.* = .{};
    }
};

/// A host-visible, coherent, persistently mapped buffer.
pub const Buffer = struct {
    buffer: vk.Buffer = .null,
    memory: vk.DeviceMemory = .null,
    size: usize = 0,
    ptr: [*]u8 = undefined,

    pub fn deinit(buf: *Buffer, gpu: *const Gpu) void {
        if (buf.buffer != .null) gpu.dev.destroyBuffer(buf.buffer, null);
        if (buf.memory != .null) {
            gpu.dev.unmapMemory(buf.memory);
            gpu.dev.freeMemory(buf.memory, null);
        }
        buf.* = .{};
    }

    pub fn write(buf: *Buffer, offset: usize, bytes: []const u8) void {
        @memcpy(buf.ptr[offset..][0..bytes.len], bytes);
    }
};

/// What the renderer records into during one frame.
pub const Frame = struct {
    cmd: vk.CommandBufferProxy,
    /// Frame-in-flight slot: per-frame resources (uniforms, instance data)
    /// indexed by it are free to overwrite.
    slot: usize,
    image_index: u32,
    extent: vk.Extent2D,
};

fn sdlGetInstanceProcAddr() vk.PfnGetInstanceProcAddr {
    return @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr());
}

pub fn init(gpa: Allocator, window: *c.SDL_Window) !*Gpu {
    const gpu = try gpa.create(Gpu);
    errdefer gpa.destroy(gpu);
    const get_proc = sdlGetInstanceProcAddr();
    const vkb = vk.BaseWrapper.load(get_proc);

    // ---- instance
    var exts: std.ArrayList([*:0]const u8) = .empty;
    defer exts.deinit(gpa);
    var sdl_count: u32 = 0;
    const sdl_exts = c.SDL_Vulkan_GetInstanceExtensions(&sdl_count) orelse return sdlFail("SDL_Vulkan_GetInstanceExtensions");
    for (sdl_exts[0..sdl_count]) |e| try exts.append(gpa, @ptrCast(e));

    const avail_exts = try vkb.enumerateInstanceExtensionPropertiesAlloc(null, gpa);
    defer gpa.free(avail_exts);
    const portability = hasExtension(avail_exts, vk.instance_extensions.khr_portability_enumeration.name);
    if (portability) try exts.append(gpa, vk.instance_extensions.khr_portability_enumeration.name);

    // Validation in debug builds, when the layer is installed.
    var layers: std.ArrayList([*:0]const u8) = .empty;
    defer layers.deinit(gpa);
    const validation_layer = "VK_LAYER_KHRONOS_validation";
    const validate = builtin.mode == .debug and hasLayer(&vkb, gpa, validation_layer) and
        hasExtension(avail_exts, vk.instance_extensions.ext_debug_utils.name);
    if (validate) {
        try layers.append(gpa, validation_layer);
        try exts.append(gpa, vk.instance_extensions.ext_debug_utils.name);
    }

    const instance_handle = try vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "chemviewer",
            .application_version = 0,
            .p_engine_name = "chemviewer",
            .engine_version = 0,
            .api_version = @bitCast(api_version),
        },
        .enabled_layer_count = @intCast(layers.items.len),
        .pp_enabled_layer_names = layers.items.ptr,
        .enabled_extension_count = @intCast(exts.items.len),
        .pp_enabled_extension_names = exts.items.ptr,
        .flags = .{ .enumerate_portability_khr = portability },
    }, null);
    const vki = try gpa.create(vk.InstanceWrapper);
    errdefer gpa.destroy(vki);
    vki.* = vk.InstanceWrapper.load(instance_handle, vkb.dispatch.vkGetInstanceProcAddr.?);
    const instance = vk.InstanceProxy.init(instance_handle, vki);
    errdefer instance.destroyInstance(null);

    var messenger: vk.DebugUtilsMessengerEXT = .null;
    if (validate) {
        messenger = try instance.createDebugUtilsMessengerEXT(&.{
            .message_severity = .{ .warning_ext = true, .error_ext = true },
            .message_type = .{ .general_ext = true, .validation_ext = true, .performance_ext = true },
            .pfn_user_callback = &debugCallback,
        }, null);
        log.info("validation layer enabled", .{});
    }
    errdefer if (messenger != .null) instance.destroyDebugUtilsMessengerEXT(messenger, null);

    // ---- surface
    var surface: vk.SurfaceKHR = .null;
    if (!c.SDL_Vulkan_CreateSurface(window, @ptrCast(instance_handle), null, @ptrCast(&surface)))
        return sdlFail("SDL_Vulkan_CreateSurface");
    errdefer instance.destroySurfaceKHR(surface, null);

    // ---- physical device: prefer a discrete GPU
    const pick = try pickDevice(instance, gpa, surface);
    const props = instance.getPhysicalDeviceProperties(pick.pdev);
    log.info("using {s}", .{std.mem.sliceTo(&props.device_name, 0)});

    // ---- device
    const dev_exts_avail = try instance.enumerateDeviceExtensionPropertiesAlloc(pick.pdev, null, gpa);
    defer gpa.free(dev_exts_avail);
    var dev_exts: std.ArrayList([*:0]const u8) = .empty;
    defer dev_exts.deinit(gpa);
    try dev_exts.append(gpa, vk.device_extensions.khr_swapchain.name);
    // MoltenVK: must be enabled whenever it is offered.
    if (hasExtension(dev_exts_avail, vk.device_extensions.khr_portability_subset.name))
        try dev_exts.append(gpa, vk.device_extensions.khr_portability_subset.name);

    var features13: vk.PhysicalDeviceVulkan13Features = .{
        .dynamic_rendering = .true,
        .synchronization_2 = .true,
        // glslc's Vulkan 1.3 target compiles `discard` to demote.
        .shader_demote_to_helper_invocation = .true,
    };
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{.{
        .queue_family_index = pick.family,
        .queue_count = 1,
        .p_queue_priorities = &priority,
    }};
    const device_handle = try instance.createDevice(pick.pdev, &.{
        .p_next = &features13,
        .queue_create_info_count = qci.len,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = @intCast(dev_exts.items.len),
        .pp_enabled_extension_names = dev_exts.items.ptr,
    }, null);
    const vkd = try gpa.create(vk.DeviceWrapper);
    errdefer gpa.destroy(vkd);
    vkd.* = vk.DeviceWrapper.load(device_handle, vki.dispatch.vkGetDeviceProcAddr.?);
    const dev = vk.DeviceProxy.init(device_handle, vkd);
    errdefer dev.destroyDevice(null);

    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pick.pdev, gpa);
    defer gpa.free(families);

    gpu.* = .{
        .gpa = gpa,
        .window = window,
        .vkb = vkb,
        .instance = instance,
        .dev = dev,
        .debug_messenger = messenger,
        .surface = surface,
        .pdev = pick.pdev,
        .props = props,
        .mem_props = instance.getPhysicalDeviceMemoryProperties(pick.pdev),
        .queue = dev.getDeviceQueue(pick.family, 0),
        .queue_family = pick.family,
        .timestamps = families[pick.family].timestamp_valid_bits > 0 and props.limits.timestamp_period > 0,
        .depth_format = try pickDepthFormat(instance, pick.pdev),
        .command_pool = undefined,
    };

    gpu.command_pool = try dev.createCommandPool(&.{
        .flags = .{ .reset_command_buffer = true },
        .queue_family_index = pick.family,
    }, null);
    var cmds: [frames_in_flight]vk.CommandBuffer = undefined;
    try dev.allocateCommandBuffers(&.{
        .command_pool = gpu.command_pool,
        .level = .primary,
        .command_buffer_count = frames_in_flight,
    }, &cmds);
    for (&gpu.frames, cmds) |*f, cmd| {
        f.* = .{
            .cmd = cmd,
            .fence = try dev.createFence(&.{ .flags = .{ .signaled = true } }, null),
            .acquired = try dev.createSemaphore(&.{}, null),
        };
    }
    try gpu.createSwapchain();
    return gpu;
}

pub fn deinit(gpu: *Gpu) void {
    const gpa = gpu.gpa;
    gpu.dev.deviceWaitIdle() catch {};
    if (gpu.readback) |*rb| rb.deinit(gpu);
    gpu.destroySwapchainResources();
    gpu.dev.destroySwapchainKHR(gpu.swapchain, null);
    for (gpu.frames) |f| {
        gpu.dev.destroyFence(f.fence, null);
        gpu.dev.destroySemaphore(f.acquired, null);
    }
    gpu.dev.destroyCommandPool(gpu.command_pool, null);
    gpu.dev.destroyDevice(null);
    gpu.instance.destroySurfaceKHR(gpu.surface, null);
    if (gpu.debug_messenger != .null) gpu.instance.destroyDebugUtilsMessengerEXT(gpu.debug_messenger, null);
    gpu.instance.destroyInstance(null);
    gpa.destroy(gpu.dev.wrapper);
    gpa.destroy(gpu.instance.wrapper);
    gpa.destroy(gpu);
}

pub fn waitIdle(gpu: *Gpu) void {
    gpu.dev.deviceWaitIdle() catch |e| log.err("vkDeviceWaitIdle: {t}", .{e});
}

/// `vkGetInstanceProcAddr`, for ImGui's backend.
pub fn getInstanceProcAddr(gpu: *const Gpu) *const anyopaque {
    return @ptrCast(gpu.vkb.dispatch.vkGetInstanceProcAddr.?);
}

// ------------------------------------------------------------ swapchain

fn windowExtent(gpu: *const Gpu) vk.Extent2D {
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(gpu.window, &w, &h);
    return .{ .width = @intCast(@max(w, 0)), .height = @intCast(@max(h, 0)) };
}

fn createSwapchain(gpu: *Gpu) !void {
    const caps = try gpu.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gpu.pdev, gpu.surface);
    var extent = caps.current_extent;
    if (extent.width == 0xFFFF_FFFF) {
        const want = gpu.windowExtent();
        extent = .{
            .width = std.math.clamp(want.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(want.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
    if (extent.width == 0 or extent.height == 0) return error.WindowMinimized;

    gpu.surface_format = try gpu.pickSurfaceFormat();
    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0) image_count = @min(image_count, caps.max_image_count);
    gpu.can_capture = caps.supported_usage_flags.transfer_src;

    const old = gpu.swapchain;
    gpu.swapchain = try gpu.dev.createSwapchainKHR(&.{
        .surface = gpu.surface,
        .min_image_count = image_count,
        .image_format = gpu.surface_format.format,
        .image_color_space = gpu.surface_format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment = true, .transfer_src = gpu.can_capture },
        .image_sharing_mode = .exclusive,
        .pre_transform = caps.current_transform,
        .composite_alpha = pickCompositeAlpha(caps.supported_composite_alpha),
        // FIFO is vsync and always available.
        .present_mode = .fifo_khr,
        .clipped = .true,
        .old_swapchain = old,
    }, null);
    if (old != .null) gpu.dev.destroySwapchainKHR(old, null);
    gpu.extent = extent;

    const gpa = gpu.gpa;
    gpu.images = try gpu.dev.getSwapchainImagesAllocKHR(gpu.swapchain, gpa);
    gpu.views = try gpa.alloc(vk.ImageView, gpu.images.len);
    gpu.render_done = try gpa.alloc(vk.Semaphore, gpu.images.len);
    for (gpu.images, gpu.views, gpu.render_done) |img, *view, *sem| {
        view.* = try gpu.createView(img, gpu.surface_format.format, .{ .color = true });
        sem.* = try gpu.dev.createSemaphore(&.{}, null);
    }

    // Not transient: `snapshotScene` stores and reloads them mid-frame.
    gpu.msaa_color = try gpu.createImage(extent.width, extent.height, gpu.surface_format.format, .{
        .color_attachment = true,
        .transfer_src = true,
    }, samples, .{ .color = true });
    gpu.depth = try gpu.createImage(extent.width, extent.height, gpu.depth_format, .{
        .depth_stencil_attachment = true,
    }, samples, .{ .depth = true });
    gpu.scene_copy = try gpu.createImage(extent.width, extent.height, gpu.surface_format.format, .{
        .sampled = true,
        .transfer_dst = true,
    }, .{ .@"1" = true }, .{ .color = true });
    gpu.scene_copy_fresh = true;
}

fn destroySwapchainResources(gpu: *Gpu) void {
    const gpa = gpu.gpa;
    for (gpu.views, gpu.render_done) |v, s| {
        gpu.dev.destroyImageView(v, null);
        gpu.dev.destroySemaphore(s, null);
    }
    gpa.free(gpu.views);
    gpa.free(gpu.render_done);
    gpa.free(gpu.images);
    gpu.views = &.{};
    gpu.render_done = &.{};
    gpu.images = &.{};
    gpu.msaa_color.deinit(gpu);
    gpu.depth.deinit(gpu);
    gpu.scene_copy.deinit(gpu);
}

fn recreateSwapchain(gpu: *Gpu) !void {
    gpu.waitIdle();
    gpu.destroySwapchainResources();
    try gpu.createSwapchain();
}

fn pickSurfaceFormat(gpu: *Gpu) !vk.SurfaceFormatKHR {
    const formats = try gpu.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(gpu.pdev, gpu.surface, gpu.gpa);
    defer gpu.gpa.free(formats);
    // UNORM: shaders output sRGB-encoded values directly, as they did with
    // OpenGL's default framebuffer; ImGui's colours assume the same.
    for ([_]vk.Format{ .b8g8r8a8_unorm, .r8g8b8a8_unorm, .a2b10g10r10_unorm_pack32 }) |want| {
        for (formats) |f| if (f.format == want and f.color_space == .srgb_nonlinear_khr) return f;
    }
    return formats[0];
}

fn pickCompositeAlpha(supported: vk.CompositeAlphaFlagsKHR) vk.CompositeAlphaFlagsKHR {
    if (supported.opaque_khr) return .{ .opaque_khr = true };
    if (supported.inherit_khr) return .{ .inherit_khr = true };
    if (supported.pre_multiplied_khr) return .{ .pre_multiplied_khr = true };
    return .{ .post_multiplied_khr = true };
}

pub fn imageCount(gpu: *const Gpu) u32 {
    return @intCast(gpu.images.len);
}

// ---------------------------------------------------------------- frame

/// Starts a frame, or returns null when there is nothing to draw into
/// (minimized window, swapchain being recreated).
pub fn beginFrame(gpu: *Gpu) !?Frame {
    const want = gpu.windowExtent();
    if (want.width == 0 or want.height == 0) return null;
    if (gpu.swapchain == .null or want.width != gpu.extent.width or want.height != gpu.extent.height) {
        gpu.recreateSwapchain() catch |e| switch (e) {
            error.WindowMinimized => return null,
            else => return e,
        };
    }

    const f = &gpu.frames[gpu.slot];
    _ = try gpu.dev.waitForFences(&.{f.fence}, .true, std.math.maxInt(u64));
    const acquired = gpu.dev.acquireNextImageKHR(gpu.swapchain, std.math.maxInt(u64), f.acquired, .null) catch |e| switch (e) {
        error.OutOfDateKHR => {
            try gpu.recreateSwapchain();
            return null;
        },
        else => return e,
    };
    try gpu.dev.resetFences(&.{f.fence});

    const cmd = vk.CommandBufferProxy.init(f.cmd, gpu.dev.wrapper);
    try cmd.resetCommandBuffer(.{});
    try cmd.beginCommandBuffer(&.{ .flags = .{ .one_time_submit = true } });
    return .{ .cmd = cmd, .slot = gpu.slot, .image_index = acquired.image_index, .extent = gpu.extent };
}

/// Begins the 4x MSAA scene pass, cleared to `clear`; it resolves into the
/// swapchain image when it ends. `resumable` stores the MSAA colour and
/// depth so that `snapshotScene` can pause and resume it; otherwise they
/// are discarded after the resolve (saving bandwidth).
pub fn beginScenePass(gpu: *Gpu, frame: Frame, clear: [3]f32, resumable: bool) void {
    const cmd = frame.cmd;
    const image = gpu.images[frame.image_index];
    gpu.barriers(cmd, &.{
        imageBarrier(image, .{ .color = true }, .undefined, .color_attachment_optimal, .{ .color_attachment_output = true }, .{}, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }),
        imageBarrier(gpu.msaa_color.image, .{ .color = true }, .undefined, .color_attachment_optimal, .{ .color_attachment_output = true, .resolve = true }, .{}, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }),
        imageBarrier(gpu.depth.image, .{ .depth = true }, .undefined, .depth_attachment_optimal, .{ .late_fragment_tests = true }, .{ .depth_stencil_attachment_write = true }, .{ .early_fragment_tests = true, .late_fragment_tests = true }, .{ .depth_stencil_attachment_read = true, .depth_stencil_attachment_write = true }),
    });
    gpu.scene_resumable = resumable;
    gpu.beginSceneRendering(frame, .clear, clear);
}

/// The scene's render pass instance. When resumable, colour and depth are
/// stored so that `snapshotScene` can resume with `.load`; every instance
/// resolves into the swapchain image (the last one wins).
fn beginSceneRendering(gpu: *Gpu, frame: Frame, load: vk.AttachmentLoadOp, clear: [3]f32) void {
    const store: vk.AttachmentStoreOp = if (gpu.scene_resumable) .store else .dont_care;
    const color: vk.RenderingAttachmentInfo = .{
        .image_view = gpu.msaa_color.view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{ .average = true },
        .resolve_image_view = gpu.views[frame.image_index],
        .resolve_image_layout = .color_attachment_optimal,
        .load_op = load,
        .store_op = store,
        .clear_value = .{ .color = .{ .float_32 = .{ clear[0], clear[1], clear[2], 1 } } },
    };
    const depth: vk.RenderingAttachmentInfo = .{
        .image_view = gpu.depth.view,
        .image_layout = .depth_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = load,
        .store_op = store,
        .clear_value = .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } },
    };
    frame.cmd.beginRendering(&.{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = frame.extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color),
        .p_depth_attachment = &depth,
    });
}

/// Pauses the scene pass, resolves what has been drawn so far into
/// `scene_copy` (left in shader_read_only_optimal for fragment shaders),
/// and resumes with colour and depth intact. Bound pipelines, sets and
/// dynamic state carry over (they belong to the command buffer).
pub fn snapshotScene(gpu: *Gpu, frame: Frame) void {
    std.debug.assert(gpu.scene_resumable);
    const cmd = frame.cmd;
    cmd.endRendering();
    const msaa = gpu.msaa_color.image;
    const copy = gpu.scene_copy.image;
    gpu.barriers(cmd, &.{
        imageBarrier(msaa, .{ .color = true }, .color_attachment_optimal, .transfer_src_optimal, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{ .resolve = true }, .{ .transfer_read = true }),
        // Earlier layers (and frames) sample it: wait for them.
        imageBarrier(copy, .{ .color = true }, .undefined, .transfer_dst_optimal, .{ .fragment_shader = true }, .{}, .{ .resolve = true }, .{ .transfer_write = true }),
    });
    const sub: vk.ImageSubresourceLayers = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 };
    cmd.resolveImage(msaa, .transfer_src_optimal, copy, .transfer_dst_optimal, &.{.{
        .src_subresource = sub,
        .src_offset = .{ .x = 0, .y = 0, .z = 0 },
        .dst_subresource = sub,
        .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
        .extent = .{ .width = frame.extent.width, .height = frame.extent.height, .depth = 1 },
    }});
    gpu.barriers(cmd, &.{
        imageBarrier(msaa, .{ .color = true }, .transfer_src_optimal, .color_attachment_optimal, .{ .resolve = true }, .{}, .{ .color_attachment_output = true }, .{ .color_attachment_read = true, .color_attachment_write = true }),
        imageBarrier(copy, .{ .color = true }, .transfer_dst_optimal, .shader_read_only_optimal, .{ .resolve = true }, .{ .transfer_write = true }, .{ .fragment_shader = true }, .{ .shader_sampled_read = true }),
        imageBarrier(gpu.depth.image, .{ .depth = true }, .depth_attachment_optimal, .depth_attachment_optimal, .{ .late_fragment_tests = true }, .{ .depth_stencil_attachment_write = true }, .{ .early_fragment_tests = true, .late_fragment_tests = true }, .{ .depth_stencil_attachment_read = true, .depth_stencil_attachment_write = true }),
        // Every instance resolves into it.
        imageBarrier(gpu.images[frame.image_index], .{ .color = true }, .color_attachment_optimal, .color_attachment_optimal, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }),
    });
    gpu.beginSceneRendering(frame, .load, .{ 0, 0, 0 });
}

pub fn endScenePass(gpu: *Gpu, frame: Frame) void {
    _ = gpu;
    frame.cmd.endRendering();
}

/// Begins a single-sampled pass over the resolved swapchain image (ImGui).
pub fn beginUiPass(gpu: *Gpu, frame: Frame) void {
    const cmd = frame.cmd;
    gpu.barriers(cmd, &.{
        imageBarrier(gpu.images[frame.image_index], .{ .color = true }, .color_attachment_optimal, .color_attachment_optimal, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{ .color_attachment_output = true }, .{ .color_attachment_read = true, .color_attachment_write = true }),
    });
    const color: vk.RenderingAttachmentInfo = .{
        .image_view = gpu.views[frame.image_index],
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = .load,
        .store_op = .store,
        .clear_value = undefined,
    };
    cmd.beginRendering(&.{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = frame.extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color),
    });
}

pub fn endUiPass(gpu: *Gpu, frame: Frame) void {
    _ = gpu;
    frame.cmd.endRendering();
}

/// Submits and presents. With `capture`, the image is also copied to host
/// memory and this waits for it: read it with `capturedPixels`.
pub fn endFrame(gpu: *Gpu, frame: Frame, capture: bool) !void {
    const cmd = frame.cmd;
    const image = gpu.images[frame.image_index];
    if (capture) {
        if (!gpu.can_capture) return error.ScreenshotUnsupported;
        const size = @as(usize, frame.extent.width) * frame.extent.height * 4;
        if (gpu.readback == null or gpu.readback.?.size < size) {
            if (gpu.readback) |*rb| rb.deinit(gpu);
            gpu.readback = try gpu.createBuffer(size, .{ .transfer_dst = true }, .{ .host_visible = true, .host_coherent = true, .host_cached = true });
        }
        gpu.barriers(cmd, &.{
            imageBarrier(image, .{ .color = true }, .color_attachment_optimal, .transfer_src_optimal, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{ .copy = true }, .{ .transfer_read = true }),
        });
        const region: vk.BufferImageCopy = .{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = frame.extent.width, .height = frame.extent.height, .depth = 1 },
        };
        cmd.copyImageToBuffer(image, .transfer_src_optimal, gpu.readback.?.buffer, &.{region});
        gpu.barriers(cmd, &.{
            imageBarrier(image, .{ .color = true }, .transfer_src_optimal, .present_src_khr, .{ .copy = true }, .{}, .{}, .{}),
        });
        cmd.pipelineBarrier2(&.{
            .memory_barrier_count = 1,
            .p_memory_barriers = &.{.{
                .src_stage_mask = .{ .copy = true },
                .src_access_mask = .{ .transfer_write = true },
                .dst_stage_mask = .{ .host = true },
                .dst_access_mask = .{ .host_read = true },
            }},
        });
    } else {
        gpu.barriers(cmd, &.{
            imageBarrier(image, .{ .color = true }, .color_attachment_optimal, .present_src_khr, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{}, .{}),
        });
    }
    try cmd.endCommandBuffer();

    const f = &gpu.frames[frame.slot];
    const done = gpu.render_done[frame.image_index];
    try gpu.dev.queueSubmit2(gpu.queue, &.{.{
        .wait_semaphore_info_count = 1,
        .p_wait_semaphore_infos = &.{.{
            .semaphore = f.acquired,
            .value = 0,
            .stage_mask = .{ .color_attachment_output = true },
            .device_index = 0,
        }},
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &.{.{ .command_buffer = f.cmd, .device_mask = 0 }},
        .signal_semaphore_info_count = 1,
        .p_signal_semaphore_infos = &.{.{
            .semaphore = done,
            .value = 0,
            .stage_mask = .{ .all_commands = true },
            .device_index = 0,
        }},
    }}, f.fence);
    gpu.slot = (gpu.slot + 1) % frames_in_flight;

    const present = gpu.dev.queuePresentKHR(gpu.queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&done),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&gpu.swapchain),
        .p_image_indices = @ptrCast(&frame.image_index),
    }) catch |e| switch (e) {
        error.OutOfDateKHR => vk.Result.suboptimal_khr,
        else => return e,
    };
    if (capture) _ = try gpu.dev.waitForFences(&.{f.fence}, .true, std.math.maxInt(u64));
    if (present == .suboptimal_khr) try gpu.recreateSwapchain();
}

/// The image copied by the last `endFrame(.., true)`, as tightly packed
/// RGBA rows from the top. Owned by the caller.
pub fn capturedPixels(gpu: *const Gpu, gpa: Allocator, extent: vk.Extent2D) ![]u8 {
    const rb = gpu.readback orelse return error.NoCapture;
    const n = @as(usize, extent.width) * extent.height * 4;
    const out = try gpa.alloc(u8, n);
    @memcpy(out, rb.ptr[0..n]);
    const bgr = switch (gpu.surface_format.format) {
        .b8g8r8a8_unorm, .b8g8r8a8_srgb => true,
        .r8g8b8a8_unorm, .r8g8b8a8_srgb => false,
        else => return error.UnsupportedCaptureFormat,
    };
    var i: usize = 0;
    while (i < n) : (i += 4) {
        if (bgr) std.mem.swap(u8, &out[i], &out[i + 2]);
        out[i + 3] = 255;
    }
    return out;
}

// ------------------------------------------------------------- helpers

pub fn barriers(gpu: *const Gpu, cmd: vk.CommandBufferProxy, list: []const vk.ImageMemoryBarrier2) void {
    _ = gpu;
    cmd.pipelineBarrier2(&.{
        .image_memory_barrier_count = @intCast(list.len),
        .p_image_memory_barriers = list.ptr,
    });
}

pub fn imageBarrier(
    image: vk.Image,
    aspect: vk.ImageAspectFlags,
    old: vk.ImageLayout,
    new: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
) vk.ImageMemoryBarrier2 {
    return .{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
        .old_layout = old,
        .new_layout = new,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
}

fn findMemoryType(gpu: *const Gpu, type_bits: u32, want: vk.MemoryPropertyFlags) !u32 {
    const mp = gpu.mem_props;
    for (mp.memory_types[0..mp.memory_type_count], 0..) |t, i| {
        if (type_bits & (@as(u32, 1) << @intCast(i)) != 0 and t.property_flags.contains(want)) return @intCast(i);
    }
    return error.NoSuitableMemoryType;
}

pub fn createBuffer(gpu: *const Gpu, size: usize, usage: vk.BufferUsageFlags, want: vk.MemoryPropertyFlags) !Buffer {
    const buffer = try gpu.dev.createBuffer(&.{
        .size = @max(size, 16),
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer gpu.dev.destroyBuffer(buffer, null);
    const req = gpu.dev.getBufferMemoryRequirements(buffer);
    // Cached readback memory is a preference, not a requirement.
    const index = gpu.findMemoryType(req.memory_type_bits, want) catch
        try gpu.findMemoryType(req.memory_type_bits, .{ .host_visible = true, .host_coherent = true });
    const memory = try gpu.dev.allocateMemory(&.{ .allocation_size = req.size, .memory_type_index = index }, null);
    errdefer gpu.dev.freeMemory(memory, null);
    try gpu.dev.bindBufferMemory(buffer, memory, 0);
    const ptr = try gpu.dev.mapMemory(memory, 0, vk.WHOLE_SIZE, .{});
    return .{ .buffer = buffer, .memory = memory, .size = size, .ptr = @ptrCast(ptr.?) };
}

/// A host-visible buffer holding `bytes`.
pub fn createBufferWith(gpu: *const Gpu, bytes: []const u8, usage: vk.BufferUsageFlags) !Buffer {
    var buf = try gpu.createBuffer(bytes.len, usage, .{ .host_visible = true, .host_coherent = true });
    buf.write(0, bytes);
    return buf;
}

pub fn createImage(
    gpu: *const Gpu,
    width: u32,
    height: u32,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    sample_count: vk.SampleCountFlags,
    aspect: vk.ImageAspectFlags,
) !Image {
    const image = try gpu.dev.createImage(&.{
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = sample_count,
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    errdefer gpu.dev.destroyImage(image, null);
    const req = gpu.dev.getImageMemoryRequirements(image);
    // Transient attachments can live in lazily allocated memory (tilers).
    const index = (if (usage.transient_attachment)
        gpu.findMemoryType(req.memory_type_bits, .{ .device_local = true, .lazily_allocated = true }) catch null
    else
        null) orelse try gpu.findMemoryType(req.memory_type_bits, .{ .device_local = true });
    const memory = try gpu.dev.allocateMemory(&.{ .allocation_size = req.size, .memory_type_index = index }, null);
    errdefer gpu.dev.freeMemory(memory, null);
    try gpu.dev.bindImageMemory(image, memory, 0);
    return .{ .image = image, .memory = memory, .view = try gpu.createView(image, format, aspect) };
}

fn createView(gpu: *const Gpu, image: vk.Image, format: vk.Format, aspect: vk.ImageAspectFlags) !vk.ImageView {
    return gpu.dev.createImageView(&.{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);
}

pub fn createShaderModule(gpu: *const Gpu, comptime name: []const u8) !vk.ShaderModule {
    const spv align(@alignOf(u32)) = @embedFile(name).*;
    return gpu.dev.createShaderModule(&.{
        .code_size = spv.len,
        .p_code = @ptrCast(&spv),
    }, null);
}

const Pick = struct { pdev: vk.PhysicalDevice, family: u32 };

fn pickDevice(instance: vk.InstanceProxy, gpa: Allocator, surface: vk.SurfaceKHR) !Pick {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(pdevs);
    var best: ?Pick = null;
    var best_score: u32 = 0;
    for (pdevs) |pdev| {
        const props = instance.getPhysicalDeviceProperties(pdev);
        if (@as(u32, @bitCast(props.api_version)) < @as(u32, @bitCast(api_version))) continue;
        const exts = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, gpa);
        defer gpa.free(exts);
        if (!hasExtension(exts, vk.device_extensions.khr_swapchain.name)) continue;
        const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, gpa);
        defer gpa.free(families);
        const family: u32 = for (families, 0..) |fam, i| {
            const idx: u32 = @intCast(i);
            if (fam.queue_flags.graphics and
                try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, idx, surface) == .true) break idx;
        } else continue;
        const score: u32 = switch (props.device_type) {
            .discrete_gpu => 3,
            .integrated_gpu => 2,
            else => 1,
        };
        if (score > best_score) {
            best_score = score;
            best = .{ .pdev = pdev, .family = family };
        }
    }
    return best orelse error.NoSuitableGpu;
}

fn pickDepthFormat(instance: vk.InstanceProxy, pdev: vk.PhysicalDevice) !vk.Format {
    for ([_]vk.Format{ .d32_sfloat, .x8_d24_unorm_pack32, .d24_unorm_s8_uint }) |f| {
        const props = instance.getPhysicalDeviceFormatProperties(pdev, f);
        if (props.optimal_tiling_features.depth_stencil_attachment) return f;
    }
    return error.NoDepthFormat;
}

fn hasExtension(list: []const vk.ExtensionProperties, name: [*:0]const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, std.mem.sliceTo(&e.extension_name, 0), std.mem.span(name))) return true;
    }
    return false;
}

fn hasLayer(vkb: *const vk.BaseWrapper, gpa: Allocator, name: []const u8) bool {
    const layers = vkb.enumerateInstanceLayerPropertiesAlloc(gpa) catch return false;
    defer gpa.free(layers);
    for (layers) |l| if (std.mem.eql(u8, std.mem.sliceTo(&l.layer_name, 0), name)) return true;
    return false;
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    types: vk.DebugUtilsMessageTypeFlagsEXT,
    data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = types;
    _ = user;
    const msg = if (data) |d| d.p_message orelse "?" else "?";
    if (severity.error_ext) log.err("{s}", .{msg}) else log.warn("{s}", .{msg});
    return .false;
}

fn sdlFail(what: []const u8) error{SdlError} {
    std.log.err("{s}: {s}", .{ what, c.SDL_GetError() });
    return error.SdlError;
}
