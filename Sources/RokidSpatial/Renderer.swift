// Draws the captured desktop as a quad floating in space, once per eye.
//
// Shaders are compiled from source at runtime rather than from a .metal file,
// which means the project builds with only the Command Line Tools installed —
// the offline `metal` compiler ships with full Xcode and is not required here.

import Foundation
import Metal
import MetalKit
import CoreVideo
import simd
import RokidKit

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Vertices arrive as float4 pairs: position (xyz, 1) then UV in (x, y).
// Real 3D positions rather than a flat local quad, because the screen
// surface may be curved — geometry is built CPU-side per frame.
vertex VertexOut vertexMain(uint vid [[vertex_id]],
                            const device float4 *vertices [[buffer(0)]],
                            constant Uniforms &uniforms [[buffer(1)]])
{
    VertexOut out;
    out.position = uniforms.mvp * float4(vertices[vid * 2].xyz, 1.0);
    out.uv = vertices[vid * 2 + 1].xy;
    return out;
}

fragment float4 fragmentMain(VertexOut in [[stage_in]],
                             texture2d<float, access::sample> tex [[texture(0)]])
{
    // No mip filtering, deliberately. Mipmapping trades sharpness for reduced
    // aliasing, and sharpness is the scarcer resource here: the desktop is
    // already being minified onto fewer panel pixels than it has points, so
    // any further softening is immediately visible as blurred text.
    constexpr sampler smp(mag_filter::linear,
                          min_filter::linear,
                          address::clamp_to_edge);
    return float4(tex.sample(smp, in.uv).rgb, 1.0);
}

// The cursor sprite keeps its alpha — it is blended over the desktop quad.
fragment float4 fragmentCursor(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> tex [[texture(0)]])
{
    constexpr sampler smp(mag_filter::linear,
                          min_filter::linear,
                          address::clamp_to_edge);
    return tex.sample(smp, in.uv);
}
"""

final class Renderer: NSObject, MTKViewDelegate {
    /// Diagonal field of view of the Rokid Max optics.
    private static let diagonalFOV: Float = 50 * .pi / 180

    /// Vertical slices in the screen mesh. Enough that a fully curved wide
    /// screen renders smoothly; irrelevant to flat screens.
    private static let meshColumns = 64
    private static let meshVertexCount = (meshColumns + 1) * 2

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private var textureCache: CVMetalTextureCache?

    // The cursor drawn by us, for glasses-only mode. The system cursor is
    // hidden there — the window server composites it above the overlay as a
    // second head-locked cursor, and hiding it also stops ScreenCaptureKit
    // from drawing it into captured frames — so this renderer paints its own
    // sprite at the same spot on the virtual screen. All coordinates are
    // fractions of the captured display so the shader stays resolution-blind.

    /// Arrow sprite; nil disables cursor drawing entirely (other modes).
    var cursorTexture: MTLTexture?
    /// Cursor image size as a fraction of each captured display (index 0 is
    /// the main screen, 1 the side screen — their point sizes differ).
    var cursorFraction = [SIMD2<Float>(0, 0), SIMD2<Float>(0, 0)]
    /// Hotspot offset within the image, as a fraction of each display.
    var cursorHotspotFraction = [SIMD2<Float>(0, 0), SIMD2<Float>(0, 0)]
    /// Called each frame; returns which surface the cursor is on (0 main,
    /// 1 side) and its UV (0…1, top-left origin), or nil to skip drawing.
    var cursorPosition: (() -> (surface: Int, uv: SIMD2<Float>)?)?

    // MARK: Side screen

    /// The side screen hangs to the right of the main one at the same
    /// distance, sharing the anchor — turn your head and it is simply there,
    /// like a second monitor. Fed by its own capture stream.
    var sideEnabled = false
    /// Angular gap between the main and side screens, radians.
    private static let sideGap: Float = 0.06

    private let filter: OrientationFilter
    private let screen: VirtualScreen

    /// Latest captured frames, handed over from the capture queues.
    private var pendingFrame: CVPixelBuffer?
    private var pendingSideFrame: CVPixelBuffer?
    private var frameLock = NSLock()
    private var currentTexture: CVMetalTexture?
    private var currentSideTexture: CVMetalTexture?
    private let sideVertexBuffer: MTLBuffer

    private var lastDrawTime = CFAbsoluteTimeGetCurrent()

    /// Set false to fall back to a single centred view, e.g. if SBS is off.
    var stereo = true

    /// Seconds of head-motion prediction. Off by default: prediction fights
    /// latency but amplifies gyroscope noise, and on this hardware the noise
    /// was the more noticeable of the two.
    var lookAhead: Float = 0

    /// Pixel dimensions of the most recent captured frame.
    private(set) var contentSize = SIMD2<Float>(0, 0)

    /// How many panel pixels the virtual screen currently spans horizontally.
    private(set) var renderedWidth: Float = 0

    init?(filter: OrientationFilter, screen: VirtualScreen) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.filter = filter
        self.screen = screen

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            // Same vertex path, alpha-blended fragment for the cursor sprite.
            // CGImage-sourced textures are premultiplied, hence .one.
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentCursor")
            let blend = descriptor.colorAttachments[0]!
            blend.isBlendingEnabled = true
            blend.sourceRGBBlendFactor = .one
            blend.sourceAlphaBlendFactor = .one
            blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
            blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            cursorPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Renderer: shader compilation failed — \(error)")
            return nil
        }

        // The screen mesh: a triangle strip of vertical slices, rebuilt each
        // frame because size, distance and curvature are all live-adjustable.
        // Flat screens waste the columns; curved ones need them.
        guard let buffer = device.makeBuffer(
            length: MemoryLayout<SIMD4<Float>>.stride * Self.meshVertexCount * 2,
            options: .storageModeShared
        ), let sideBuffer = device.makeBuffer(
            length: MemoryLayout<SIMD4<Float>>.stride * Self.meshVertexCount * 2,
            options: .storageModeShared
        ) else { return nil }
        vertexBuffer = buffer
        sideVertexBuffer = sideBuffer

        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Hand a freshly captured frame to the renderer. Safe to call from any queue.
    func submit(frame: CVPixelBuffer) {
        frameLock.lock()
        pendingFrame = frame
        frameLock.unlock()
    }

    /// Same, for the side screen's capture stream.
    func submitSide(frame: CVPixelBuffer) {
        frameLock.lock()
        pendingSideFrame = frame
        frameLock.unlock()
    }

    /// Rotate `point` about the anchor's vertical axis — how the side screen
    /// swings away from the main one.
    private static func rotateY(_ point: SIMD3<Float>, _ angle: Float) -> SIMD3<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD3(point.x * c + point.z * s, point.y, -point.x * s + point.z * c)
    }

    /// Fill a mesh buffer with the screen surface, optionally swung by
    /// `azimuth` radians about the vertical axis.
    private func fillMesh(_ buffer: MTLBuffer, aspect: Float, azimuth: Float) {
        let mesh = buffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: Self.meshVertexCount * 2)
        for column in 0...Self.meshColumns {
            let u = Float(column) / Float(Self.meshColumns)
            var bottom = screen.surfacePoint(u: u, v: 1, aspect: aspect)
            var top = screen.surfacePoint(u: u, v: 0, aspect: aspect)
            if azimuth != 0 {
                bottom = Self.rotateY(bottom, azimuth)
                top = Self.rotateY(top, azimuth)
            }
            let base = column * 4
            mesh[base + 0] = SIMD4(bottom.x, bottom.y, bottom.z, 1)
            mesh[base + 1] = SIMD4(u, 1, 0, 0)
            mesh[base + 2] = SIMD4(top.x, top.y, top.z, 1)
            mesh[base + 3] = SIMD4(u, 0, 0, 0)
        }
    }

    /// The side screen's centre direction relative to the main screen's,
    /// radians about the vertical axis. Negative swings right.
    private func sideAzimuth(mainAspect: Float, sideAspect: Float) -> Float {
        let mainHalf = screen.size(aspect: mainAspect).x / (2 * screen.distance)
        let sideHalf = screen.size(aspect: sideAspect).x / (2 * screen.distance)
        return -(mainHalf + sideHalf + Self.sideGap)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(now - lastDrawTime)
        lastDrawTime = now

        let head = filter.predictedRelativeOrientation(lookAhead: lookAhead)
        screen.update(head: head, dt: dt,
                      rotationRate: simd_length(filter.angularVelocity))

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let texture = prepareTexture(commandBuffer: commandBuffer)

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        if let texture {
            let width = Double(view.drawableSize.width)
            let height = Double(view.drawableSize.height)
            // In SBS the framebuffer holds both eyes across its width, so each
            // eye's viewport is half as wide but keeps the full aspect ratio.
            let eyeWidth = stereo ? width / 2 : width
            let aspect = Float(eyeWidth / height)

            let contentAspect = Float(texture.width) / Float(texture.height)
            let model = screen.anchorRotation()

            // Rebuild the screen surfaces: alternating bottom/top vertices
            // per column form one triangle strip across each (possibly
            // curved) surface, positions in the anchor's local frame.
            fillMesh(vertexBuffer, aspect: contentAspect, azimuth: 0)

            let sideTexture = sideEnabled ? prepareSideTexture() : nil
            var azimuth: Float = 0
            var sideAspect: Float = 1
            if let sideTexture {
                sideAspect = Float(sideTexture.width) / Float(sideTexture.height)
                azimuth = sideAzimuth(mainAspect: contentAspect, sideAspect: sideAspect)
                fillMesh(sideVertexBuffer, aspect: sideAspect, azimuth: azimuth)
            }

            // Convert the quoted diagonal FOV into the vertical one Metal wants.
            let diagonalTangent = tan(Self.diagonalFOV / 2)
            let verticalTangent = diagonalTangent / (1 + aspect * aspect).squareRoot()
            let fovY = 2 * atan(verticalTangent)
            let projection = simd_float4x4.perspective(
                fovYRadians: fovY, aspect: aspect, near: 0.05, far: 100
            )

            // How many panel pixels the virtual screen actually spans. Compared
            // against the captured width, this is the sharpness budget: below
            // 1.0 the desktop is being squeezed into fewer pixels than it has,
            // and no amount of filtering can put the detail back.
            let extent = screen.size(aspect: contentAspect)
            renderedWidth = Float(eyeWidth) * extent.x
                / (screen.distance * 2 * tan(fovY / 2) * aspect)

            // The cursor quad sits on whichever surface the mouse is on, at
            // its fractional position — its corners go through the same
            // surface mapping, so it follows curvature and the side swing.
            var cursorVertices: [SIMD4<Float>]?
            if let position = cursorPosition?(), cursorTexture != nil,
               position.surface == 0 || sideTexture != nil {
                let onSide = position.surface == 1
                let fraction = cursorFraction[position.surface]
                let hotspot = cursorHotspotFraction[position.surface]
                let aspect = onSide ? sideAspect : contentAspect
                let u0 = position.uv.x - hotspot.x
                let v0 = position.uv.y - hotspot.y
                let u1 = u0 + fraction.x
                let v1 = v0 + fraction.y
                // Nudged toward the viewer so it never z-fights the screen.
                cursorVertices = [
                    (u0, v1, SIMD2<Float>(0, 1)),
                    (u1, v1, SIMD2<Float>(1, 1)),
                    (u0, v0, SIMD2<Float>(0, 0)),
                    (u1, v0, SIMD2<Float>(1, 0)),
                ].flatMap { (u, v, uv) -> [SIMD4<Float>] in
                    var p = screen.surfacePoint(u: u, v: v, aspect: aspect)
                    if onSide { p = Self.rotateY(p, azimuth) }
                    p *= 0.995
                    return [SIMD4(p.x, p.y, p.z, 1), SIMD4(uv.x, uv.y, 0, 0)]
                }
            }

            let eyes: [(offset: Float, originX: Double)] = stereo
                ? [(-screen.ipd / 2, 0), (screen.ipd / 2, eyeWidth)]
                : [(0, 0)]

            for eye in eyes {
                encoder.setViewport(MTLViewport(
                    originX: eye.originX, originY: 0,
                    width: eyeWidth, height: height,
                    znear: 0, zfar: 1
                ))
                let view = screen.viewMatrix(head: head, eyeOffset: eye.offset)
                var uniforms = projection * view * model
                encoder.setVertexBytes(&uniforms,
                                       length: MemoryLayout<simd_float4x4>.size,
                                       index: 1)

                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                       vertexCount: Self.meshVertexCount)

                if let sideTexture {
                    encoder.setVertexBuffer(sideVertexBuffer, offset: 0, index: 0)
                    encoder.setFragmentTexture(sideTexture, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                           vertexCount: Self.meshVertexCount)
                }

                if let cursorVertices, let cursorTexture {
                    encoder.setRenderPipelineState(cursorPipeline)
                    encoder.setVertexBytes(cursorVertices,
                                           length: MemoryLayout<SIMD4<Float>>.stride * cursorVertices.count,
                                           index: 0)
                    encoder.setFragmentTexture(cursorTexture, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Wrap the most recent captured pixel buffer as a Metal texture.
    ///
    /// The `CVMetalTexture` is retained until the next frame replaces it, which
    /// keeps the underlying IOSurface alive for as long as the GPU is reading
    /// from it. If no new frame has arrived, the previous one is redrawn — the
    /// head has still moved, so the geometry needs updating even when the
    /// desktop is idle.
    private func prepareTexture(commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        frameLock.lock()
        let frame = pendingFrame
        frameLock.unlock()

        let previous = currentTexture.flatMap { CVMetalTextureGetTexture($0) }
        guard let frame, let textureCache else { return previous }

        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)

        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, frame, nil,
            .bgra8Unorm, width, height, 0, &wrapped
        )
        guard status == kCVReturnSuccess,
              let wrapped,
              let source = CVMetalTextureGetTexture(wrapped)
        else { return previous }
        currentTexture = wrapped

        contentSize = SIMD2(Float(width), Float(height))
        return source
    }

    /// Side-screen counterpart of `prepareTexture`.
    private func prepareSideTexture() -> MTLTexture? {
        frameLock.lock()
        let frame = pendingSideFrame
        frameLock.unlock()

        let previous = currentSideTexture.flatMap { CVMetalTextureGetTexture($0) }
        guard let frame, let textureCache else { return previous }

        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, frame, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), 0, &wrapped
        )
        guard status == kCVReturnSuccess,
              let wrapped,
              let source = CVMetalTextureGetTexture(wrapped)
        else { return previous }
        currentSideTexture = wrapped
        return source
    }
}
