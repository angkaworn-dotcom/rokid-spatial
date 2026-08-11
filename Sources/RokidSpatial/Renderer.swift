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

// Two matrices, blended per vertex by the V texture coordinate. The panel
// scans top to bottom, so lower rows light up later and want *more* motion
// prediction; mvpTop is the transform for the first scanline and mvpBottom
// for the last, a few milliseconds further along the head's rotation. The
// angular difference is tiny (≤ ~2°), so lerping clip positions is fine.
struct Uniforms {
    float4x4 mvpTop;
    float4x4 mvpBottom;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Vertices arrive packed as (x, y, u, v): the quad is flat in its local
// frame, so the z coordinate is always zero and the slot is reused for UV.
vertex VertexOut vertexMain(uint vid [[vertex_id]],
                            const device float4 *vertices [[buffer(0)]],
                            constant Uniforms &uniforms [[buffer(1)]])
{
    float4 v = vertices[vid];
    VertexOut out;
    float4 top = uniforms.mvpTop * float4(v.xy, 0.0, 1.0);
    float4 bottom = uniforms.mvpBottom * float4(v.xy, 0.0, 1.0);
    out.position = mix(top, bottom, v.w);
    out.uv = v.zw;
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
    /// Cursor image size as a fraction of the captured display.
    var cursorFraction = SIMD2<Float>(0, 0)
    /// Hotspot offset within the image, as a fraction of the display.
    var cursorHotspotFraction = SIMD2<Float>(0, 0)
    /// Called each frame; returns the cursor position as UV (0…1, top-left
    /// origin) on the captured display, or nil to skip drawing.
    var cursorPosition: (() -> SIMD2<Float>?)?

    private let filter: OrientationFilter
    private let screen: VirtualScreen

    /// Latest captured frame, handed over from the capture queue.
    private var pendingFrame: CVPixelBuffer?
    private var frameLock = NSLock()
    private var currentTexture: CVMetalTexture?

    private var lastDrawTime = CFAbsoluteTimeGetCurrent()

    /// Set false to fall back to a single centred view, e.g. if SBS is off.
    var stereo = true

    /// Seconds of head-motion prediction. Off by default: prediction fights
    /// latency but amplifies gyroscope noise, and on this hardware the noise
    /// was the more noticeable of the two.
    var lookAhead: Float = 0

    /// Breezy-style automatic look-ahead. When on, `lookAhead` is ignored and
    /// the prediction interval comes from XRLinuxDriver's Rokid-tuned values:
    /// 20 ms + 0.6 × frametime, capped at 40 ms, plus an extra 8 ms ramped
    /// down the frame because the panel scans top to bottom. Velocity comes
    /// from differencing the *fused* orientation between frames rather than
    /// from the gyro — the filter's smoothness carries into the prediction,
    /// which is what kept breezy's version from jittering where ours did.
    var autoLookAhead = false

    private static let autoConstant: Float = 0.020
    private static let autoFrametimeMultiplier: Float = 0.6
    private static let autoCap: Float = 0.040
    private static let autoScanlineAdjust: Float = 0.008

    /// World-frame angular velocity from pose differencing, lightly smoothed.
    private var poseVelocity = SIMD3<Float>(repeating: 0)
    private var previousHead: simd_quatf?
    private var smoothedFrametime: Float = 1.0 / 120.0

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

        // Triangle strip over the unit quad. Texture V is flipped because
        // Metal samples with the origin at the top left.
        let vertices: [SIMD4<Float>] = [
            SIMD4(-1, -1, 0, 1),
            SIMD4( 1, -1, 1, 1),
            SIMD4(-1,  1, 0, 0),
            SIMD4( 1,  1, 1, 0),
        ]
        guard let buffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<SIMD4<Float>>.stride * vertices.count,
            options: .storageModeShared
        ) else { return nil }
        vertexBuffer = buffer

        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Hand a freshly captured frame to the renderer. Safe to call from any queue.
    func submit(frame: CVPixelBuffer) {
        frameLock.lock()
        pendingFrame = frame
        frameLock.unlock()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// The head orientation `interval` seconds from now, extrapolated along
    /// the pose-differenced velocity. World-frame, so it pre-multiplies.
    private func predictHead(_ head: simd_quatf, interval: Float) -> simd_quatf {
        let speed = simd_length(poseVelocity)
        guard interval > 0, speed > 1e-4 else { return head }
        let step = simd_quatf(angle: speed * interval, axis: poseVelocity / speed)
        return (step * head).normalized
    }

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(now - lastDrawTime)
        lastDrawTime = now

        // The unpredicted head drives the anchor logic — predicting there
        // would make follow mode chase a place the head never quite reaches.
        let head = filter.relativeOrientation
        screen.update(head: head, dt: dt,
                      rotationRate: simd_length(filter.angularVelocity))

        // Velocity by differencing consecutive fused orientations. The filter
        // has already smoothed and gravity-corrected them, so this is far
        // calmer than the gyro; a light EMA settles the remainder.
        if dt > 0, dt < 0.5 {
            smoothedFrametime += (dt - smoothedFrametime) * min(1, dt / 0.25)
            if let previous = previousHead {
                let delta = (head * previous.inverse).normalized
                let angle = 2 * acos(min(max(abs(delta.real), -1), 1))
                let axisLength = simd_length(delta.imag)
                let instantaneous = axisLength > 1e-6 && angle > 1e-6
                    ? delta.imag / axisLength * (delta.real < 0 ? -1 : 1) * (angle / dt)
                    : SIMD3<Float>(repeating: 0)
                poseVelocity += (instantaneous - poseVelocity) * min(1, dt / 0.030)
            }
        }
        previousHead = head

        // Prediction interval: breezy's Rokid tuning when automatic, the
        // manual slider otherwise. The scanline term only exists in auto.
        let baseInterval: Float
        let scanlineInterval: Float
        if autoLookAhead {
            baseInterval = min(Self.autoConstant
                               + Self.autoFrametimeMultiplier * smoothedFrametime,
                               Self.autoCap)
            scanlineInterval = Self.autoScanlineAdjust
        } else {
            baseInterval = lookAhead
            scanlineInterval = 0
        }
        let headTop = predictHead(head, interval: baseInterval)
        let headBottom = scanlineInterval > 0
            ? predictHead(head, interval: baseInterval + scanlineInterval)
            : headTop

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
            let model = screen.modelMatrix(aspect: contentAspect)

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

            // The cursor quad lives on the same plane as the screen quad, at
            // the mouse's fractional position. Local plane coordinates run
            // x = 2u−1, y = 1−2v (v is top-left like the texture).
            var cursorVertices: [SIMD4<Float>]?
            var cursorScanline: Float = 0
            if let position = cursorPosition?(), cursorTexture != nil {
                let u0 = position.x - cursorHotspotFraction.x
                let v0 = position.y - cursorHotspotFraction.y
                let u1 = u0 + cursorFraction.x
                let v1 = v0 + cursorFraction.y
                cursorScanline = position.y
                cursorVertices = [
                    SIMD4(2 * u0 - 1, 1 - 2 * v1, 0, 1),
                    SIMD4(2 * u1 - 1, 1 - 2 * v1, 1, 1),
                    SIMD4(2 * u0 - 1, 1 - 2 * v0, 0, 0),
                    SIMD4(2 * u1 - 1, 1 - 2 * v0, 1, 0),
                ]
            }
            // The cursor sprite's own V coordinate is sprite-local, so the
            // scanline blend must not apply across it; it gets one transform,
            // predicted for the scanline the sprite actually sits on.
            let headCursor = scanlineInterval > 0
                ? predictHead(head, interval: baseInterval + scanlineInterval * cursorScanline)
                : headTop

            let eyes: [(offset: Float, originX: Double)] = stereo
                ? [(-screen.ipd / 2, 0), (screen.ipd / 2, eyeWidth)]
                : [(0, 0)]

            struct EyeUniforms {
                var mvpTop: simd_float4x4
                var mvpBottom: simd_float4x4
            }

            for eye in eyes {
                encoder.setViewport(MTLViewport(
                    originX: eye.originX, originY: 0,
                    width: eyeWidth, height: height,
                    znear: 0, zfar: 1
                ))
                let viewTop = screen.viewMatrix(head: headTop, eyeOffset: eye.offset)
                let viewBottom = screen.viewMatrix(head: headBottom, eyeOffset: eye.offset)
                var uniforms = EyeUniforms(
                    mvpTop: projection * viewTop * model,
                    mvpBottom: projection * viewBottom * model
                )
                encoder.setVertexBytes(&uniforms,
                                       length: MemoryLayout<EyeUniforms>.size,
                                       index: 1)

                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

                if let cursorVertices, let cursorTexture {
                    let viewCursor = screen.viewMatrix(head: headCursor, eyeOffset: eye.offset)
                    let mvpCursor = projection * viewCursor * model
                    var cursorUniforms = EyeUniforms(mvpTop: mvpCursor, mvpBottom: mvpCursor)
                    encoder.setVertexBytes(&cursorUniforms,
                                           length: MemoryLayout<EyeUniforms>.size,
                                           index: 1)
                    encoder.setRenderPipelineState(cursorPipeline)
                    encoder.setVertexBytes(cursorVertices,
                                           length: MemoryLayout<SIMD4<Float>>.stride * 4,
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
}
