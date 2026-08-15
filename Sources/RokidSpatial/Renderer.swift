// Draws the captured desktop as a quad floating in space.
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

// Shared fragment parameters. tint.rgb = per-channel gains (eye care),
// tint.a = overall dim (head-down peek). misc.x = sharpen strength 0-1.
struct FragParams {
    float4 tint;
    float4 misc;
};

// Unsharp mask clamped to the local min/max — the clamp is what separates
// "text pops" from "text grows white halos". Four extra taps; base already
// paid for. Counteracts the softening bilinear filtering adds whenever the
// desktop sits at a sub-pixel offset, which under head tracking is always.
static float3 sharpened(float3 base, texture2d<float, access::sample> tex,
                        sampler smp, float2 uv, float amount)
{
    float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
    float3 n = tex.sample(smp, uv + float2(0, -texel.y)).rgb;
    float3 s = tex.sample(smp, uv + float2(0,  texel.y)).rgb;
    float3 e = tex.sample(smp, uv + float2( texel.x, 0)).rgb;
    float3 w = tex.sample(smp, uv + float2(-texel.x, 0)).rgb;
    float3 blur = (n + s + e + w) * 0.25;
    float3 lo = min(base, min(min(n, s), min(e, w)));
    float3 hi = max(base, max(max(n, s), max(e, w)));
    return clamp(base + (base - blur) * (amount * 1.5), lo, hi);
}

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
                             texture2d<float, access::sample> tex [[texture(0)]],
                             constant FragParams &params [[buffer(0)]])
{
    // No mip filtering, deliberately. Mipmapping trades sharpness for reduced
    // aliasing, and sharpness is the scarcer resource here: the desktop is
    // already being minified onto fewer panel pixels than it has points, so
    // any further softening is immediately visible as blurred text.
    constexpr sampler smp(mag_filter::linear,
                          min_filter::linear,
                          address::clamp_to_edge);
    float3 c = tex.sample(smp, in.uv).rgb;
    if (params.misc.x > 0.001) {
        c = sharpened(c, tex, smp, in.uv, params.misc.x);
    }
    return float4(c * params.tint.rgb * params.tint.a, 1.0);
}

// Catmull-Rom in 9 bilinear taps — the 4×4 kernel evaluated as 3×3
// bilinear fetches whose offsets encode the weights. Negative lobes keep
// edges tight where plain bilinear smears them.
static float3 catmullSample(texture2d<float, access::sample> tex,
                            sampler smp, float2 uv)
{
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 pos = uv * size;
    float2 centre = floor(pos - 0.5) + 0.5;
    float2 f = pos - centre;
    float2 f2 = f * f, f3 = f2 * f;

    float2 w0 = -0.5 * f3 + f2 - 0.5 * f;
    float2 w1 =  1.5 * f3 - 2.5 * f2 + 1.0;
    float2 w2 = -1.5 * f3 + 2.0 * f2 + 0.5 * f;
    float2 w3 =  0.5 * f3 - 0.5 * f2;
    float2 w12 = w1 + w2;

    float2 t0 = (centre - 1.0) / size;
    float2 t12 = (centre + w2 / w12) / size;
    float2 t3 = (centre + 2.0) / size;

    float3 c =
        tex.sample(smp, float2(t0.x,  t0.y)).rgb  * w0.x  * w0.y +
        tex.sample(smp, float2(t12.x, t0.y)).rgb  * w12.x * w0.y +
        tex.sample(smp, float2(t3.x,  t0.y)).rgb  * w3.x  * w0.y +
        tex.sample(smp, float2(t0.x,  t12.y)).rgb * w0.x  * w12.y +
        tex.sample(smp, float2(t12.x, t12.y)).rgb * w12.x * w12.y +
        tex.sample(smp, float2(t3.x,  t12.y)).rgb * w3.x  * w12.y +
        tex.sample(smp, float2(t0.x,  t3.y)).rgb  * w0.x  * w3.y +
        tex.sample(smp, float2(t12.x, t3.y)).rgb  * w12.x * w3.y +
        tex.sample(smp, float2(t3.x,  t3.y)).rgb  * w3.x  * w3.y;
    return max(c, 0.0);
}

// Crisp-sampling variant: Catmull-Rom instead of bilinear. Plain bilinear
// visibly blurs text whenever the desktop is *magnified* onto more panel
// pixels than it has points (the small virtual-desktop sizes); at 1:1 it
// degrades gracefully to nearly the same image.
fragment float4 fragmentCrisp(VertexOut in [[stage_in]],
                              texture2d<float, access::sample> tex [[texture(0)]],
                              constant FragParams &params [[buffer(0)]])
{
    constexpr sampler smp(mag_filter::linear,
                          min_filter::linear,
                          address::clamp_to_edge);
    float3 c = catmullSample(tex, smp, in.uv);
    if (params.misc.x > 0.001) {
        c = sharpened(c, tex, smp, in.uv, params.misc.x);
    }
    return float4(c * params.tint.rgb * params.tint.a, 1.0);
}

// Anti-moiré variant: a 4-tap rotated-grid supersample, taps spread across
// this pixel's texture footprint via screen-space UV gradients. At ~1:1
// scale plain bilinear makes the desktop's pixel rows beat against the
// panel raster whenever the head moves — faint grey bands that crawl with
// sub-pixel sampling phase. Averaging four offset taps flattens the beat
// at the cost of a slight softening.
fragment float4 fragmentSmooth(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> tex [[texture(0)]],
                               constant FragParams &params [[buffer(0)]])
{
    constexpr sampler smp(mag_filter::linear,
                          min_filter::linear,
                          address::clamp_to_edge);
    float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
    float3 c = (tex.sample(smp, in.uv + 0.125*dx + 0.375*dy).rgb
              + tex.sample(smp, in.uv - 0.375*dx + 0.125*dy).rgb
              + tex.sample(smp, in.uv - 0.125*dx - 0.375*dy).rgb
              + tex.sample(smp, in.uv + 0.375*dx - 0.125*dy).rgb) * 0.25;
    if (params.misc.x > 0.001) {
        c = sharpened(c, tex, smp, in.uv, params.misc.x);
    }
    return float4(c * params.tint.rgb * params.tint.a, 1.0);
}

// Temporal supersampling accumulation. The scene is a rotation-only camera
// looking at screens, so last frame's image reprojects onto this frame's
// with a pure direction rotation — no depth needed, no disocclusion. Each
// output pixel blends the freshly rendered scene with the reprojected
// history, clamped to the scene's 3×3 neighbourhood so moving content
// (scrolling, video, the fade of a peek) sheds stale history immediately
// instead of ghosting. Head micro-motion supplies the sub-pixel phase
// diversity that makes the average carry more detail than one frame.
struct AccumParams {
    float4 reproj0;   // rows of the current→previous direction rotation
    float4 reproj1;
    float4 reproj2;
    float4 info;      // x = tan(fovX/2), y = tan(fovY/2), z = history alpha
};

struct AccumOut {
    float4 display [[color(0)]];
    float4 history [[color(1)]];
};

fragment AccumOut fragmentAccum(VertexOut in [[stage_in]],
                                texture2d<float, access::sample> scene [[texture(0)]],
                                texture2d<float, access::sample> history [[texture(1)]],
                                constant AccumParams &p [[buffer(0)]])
{
    constexpr sampler smp(mag_filter::linear,
                          min_filter::linear,
                          address::clamp_to_edge);
    float3 cur = scene.sample(smp, in.uv).rgb;

    float3 outc = cur;
    if (p.info.z > 0.001) {
        // Where did this pixel's view direction land last frame?
        float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
        float3 dir = float3(ndc.x * p.info.x, ndc.y * p.info.y, -1.0);
        float3x3 rot = float3x3(p.reproj0.xyz, p.reproj1.xyz, p.reproj2.xyz);
        float3 prev = rot * dir;
        if (prev.z < -1e-4) {
            float2 ndcPrev = float2((prev.x / -prev.z) / p.info.x,
                                    (prev.y / -prev.z) / p.info.y);
            float2 uvPrev = float2(ndcPrev.x * 0.5 + 0.5, 0.5 - ndcPrev.y * 0.5);
            if (all(uvPrev >= 0.0) && all(uvPrev <= 1.0)) {
                // Neighbourhood clamp: history may not stray outside what
                // the current frame could plausibly contain.
                float2 texel = 1.0 / float2(scene.get_width(), scene.get_height());
                float3 mn = cur, mx = cur;
                for (int dy = -1; dy <= 1; ++dy) {
                    for (int dx = -1; dx <= 1; ++dx) {
                        if (dx == 0 && dy == 0) continue;
                        float3 s = scene.sample(smp, in.uv + float2(dx, dy) * texel).rgb;
                        mn = min(mn, s);
                        mx = max(mx, s);
                    }
                }
                // Catmull-Rom, not bilinear: the history is resampled every
                // frame, and bilinear's smear compounds under accumulation —
                // "text is sharper with it off" was the live verdict on the
                // bilinear version.
                float3 hist = clamp(catmullSample(history, smp, uvPrev), mn, mx);
                outc = mix(cur, hist, p.info.z);
            }
        }
    }
    float4 c = float4(outc, 1.0);
    return AccumOut { c, c };
}

// The cursor sprite keeps its alpha — it is blended over the desktop quad.
fragment float4 fragmentCursor(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> tex [[texture(0)]],
                               constant FragParams &params [[buffer(0)]])
{
    constexpr sampler smp(mag_filter::linear,
                          min_filter::linear,
                          address::clamp_to_edge);
    float4 c = tex.sample(smp, in.uv);
    return float4(c.rgb * params.tint.rgb * params.tint.a, c.a * params.tint.a);
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
    // Two of each pipeline: index 0 renders into a plain bgra8Unorm
    // framebuffer, index 1 into the sRGB one linear-light mode uses. The
    // set is picked per frame from the drawable's *actual* format, so a
    // live toggle can never pair a pipeline with a mismatched attachment.
    private let pipelines: [MTLRenderPipelineState]
    private let smoothPipelines: [MTLRenderPipelineState]
    private let crispPipelines: [MTLRenderPipelineState]
    private let cursorPipelines: [MTLRenderPipelineState]

    /// Selects the anti-moiré fragment path; flippable live from settings.
    var antiMoire = false

    /// Catmull-Rom sampling instead of bilinear — tighter text when the
    /// desktop is magnified. Anti-moiré wins when both are on: minification
    /// aliasing is the uglier artefact.
    var crisp = false

    /// Post-sample sharpening strength, 0 (off) to 1. Applied in every
    /// desktop fragment path, never to the cursor sprite.
    var sharpen: Float = 0

    /// Linear-light filtering: decode sRGB *before* bilinear interpolation
    /// (an sRGB-view of the capture), filter and sharpen in linear, and let
    /// the sRGB drawable re-encode on write. Gamma-space filtering — the
    /// default everywhere, including here until now — darkens the fringe
    /// pixels of text; linear is the mathematically right blend. Whether
    /// "right" also reads *better* is for the eyes: correct edges are
    /// fractionally softer-looking than gamma's artificially dark ones.
    /// This flag drives the capture-texture view format; the framebuffer
    /// side follows the view's colorPixelFormat, set by the controller.
    var linearLight = false

    /// Temporal supersampling: accumulate frames in a reprojected history
    /// buffer.
    var temporalSS = false

    // TSS state. The scene renders offscreen, the accumulation pass writes
    // the drawable and the new history in one MRT pass, and the cursor is
    // drawn on top afterwards — a sprite that moves every frame has no
    // business being temporally accumulated.
    private var accumPipelines: [MTLRenderPipelineState] = []
    private var sceneTexture: MTLTexture?
    private var historyTextures: [MTLTexture?] = [nil, nil]
    private var historyIndex = 0
    private var historyValid = false
    private var prevRenderHead = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private let fsQuadBuffer: MTLBuffer

    /// How much of the blend is history. 0.88 ≈ an effective window of
    /// several frames — enough accumulation to matter, short enough that
    /// the clamp keeps motion clean.
    private let temporalAlpha: Float = 0.88

    /// CPU-side mirror of the shader's FragParams.
    private struct FragParams {
        var tint: SIMD4<Float>
        var misc: SIMD4<Float>
    }

    /// Head-down peek (idea borrowed from VITURE's SpaceWalker): as the head
    /// pitches down toward the keyboard the whole render fades to black, and
    /// black on a birdbath panel is see-through — so looking down shows the
    /// real desk, looking back up brings the screen back. The fade runs over
    /// an angle range rather than a switch, and the pose it reads is already
    /// steady-smoothed, so there is nothing to debounce.
    var headDownPeek = false
    /// Pitch (degrees) where the fade begins; fully dark 20 degrees later.
    /// User-tunable — how deep a "glance at the keyboard" is depends on
    /// posture and screen height.
    var peekAngle: Float = 35

    /// Eye-care warmth, 0 (off) to 1: pulls blue (and a little green) out of
    /// every fragment, Night-Shift style, but inside our own pipeline — so
    /// it applies in every mode and costs nothing extra.
    var eyeCare: Float = 0

    /// Per-axis tracking locks (SpaceWalker's Restrict Tilt/Turn). Applied to
    /// the pose used for anchoring and viewing; the head-down peek reads the
    /// raw pitch first, so a pitch lock cannot break the keyboard glance.
    var axisLocks = AxisLocks()

    /// The frame-duration budget a draw is judged against, matching the
    /// panel's configured refresh rate.
    var targetFPS = 120
    private let vertexBuffer: MTLBuffer
    private var textureCache: CVMetalTextureCache?

    // The cursor drawn by us, for glasses-only mode. The system cursor is
    // hidden there — the window server composites it above the overlay as a
    // second head-locked cursor, and hiding it also stops ScreenCaptureKit
    // from drawing it into captured frames — so this renderer paints its own
    // sprite at the same spot on the virtual screen. All coordinates are
    // fractions of the captured display so the shader stays resolution-blind.

    /// Current cursor sprite; nil disables cursor drawing entirely (other
    /// modes). Swapped from the main thread whenever the system cursor
    /// changes shape (resize arrows, I-beam, pointing hand) and read on the
    /// render thread — hence the lock and the one-shot snapshot in draw.
    private var cursorTexture: MTLTexture?
    private let cursorLock = NSLock()
    /// Cursor image size as a fraction of each captured display (index 0 is
    /// the main screen, then the side screens — point sizes differ).
    private var cursorFraction = [SIMD2<Float>](repeating: .zero, count: 3)
    /// Hotspot offset within the image, as a fraction of each display.
    private var cursorHotspotFraction = [SIMD2<Float>](repeating: .zero, count: 3)

    /// Swap the drawn cursor: sprite, its per-surface size and hotspot.
    func setCursorSprite(texture: MTLTexture?,
                         fraction: [SIMD2<Float>],
                         hotspot: [SIMD2<Float>]) {
        cursorLock.lock()
        cursorTexture = texture
        cursorFraction = fraction
        cursorHotspotFraction = hotspot
        cursorLock.unlock()
    }

    /// Angular position of each active side screen this frame (radians,
    /// nil = inactive), published by draw so the shake-warp can ask which
    /// screen the head is aimed at. Guarded by cursorLock.
    private var lastAzimuths: [Float?] = [nil, nil]

    /// Which surface the head is looking at: 0 main, 1 right side, 2 left.
    /// A side wins when the gaze is angularly closer to it than to centre.
    func lookedSurface(yawRadians: Float) -> Int {
        cursorLock.lock(); defer { cursorLock.unlock() }
        for (index, azimuth) in lastAzimuths.enumerated() {
            guard let azimuth else { continue }
            if abs(yawRadians - azimuth) < abs(yawRadians) { return index + 1 }
        }
        return 0
    }

    /// Called each frame; returns which surface the cursor is on (0 main,
    /// 1 right side, 2 left side) and its UV (0…1, top-left origin), or nil
    /// to skip drawing.
    var cursorPosition: (() -> (surface: Int, uv: SIMD2<Float>)?)?

    // MARK: Side screens

    /// Side screens hang left and right of the main one at the same distance,
    /// sharing the anchor — turn your head and they are simply there, like
    /// extra monitors. Each is fed by its own capture stream.
    /// Index 0 = right, 1 = left; set true once its capture is running.
    var sideActive = [false, false]
    /// Angular gap between neighbouring screens, radians. Zero butts the
    /// screens together into one long wall — best combined with curvature.
    var sideGap: Float = 0.05
    /// Stacked layout (SpaceWalker's "3 Stacked Displays"): the sides hang
    /// above (index 0) and below (index 1) the main screen instead of
    /// beside it — the swing becomes elevation about X rather than azimuth
    /// about Y.
    var sideStacked = false

    private let filter: OrientationFilter
    private let screen: VirtualScreen

    /// Latest captured frames, handed over from the capture queues.
    private var pendingFrame: CVPixelBuffer?
    private var pendingSideFrames: [CVPixelBuffer?] = [nil, nil]
    private var frameLock = NSLock()
    private var currentTexture: CVMetalTexture?
    private var currentSideTextures: [CVMetalTexture?] = [nil, nil]
    private let sideVertexBuffers: [MTLBuffer]

    private var lastDrawTime = CFAbsoluteTimeGetCurrent()

    /// Frame-pacing counters, read and reset once a second by the status
    /// display. A "long" frame overshot the target-rate deadline by half a frame —
    /// exactly the hiccups that read as stutter in the glasses. Written on
    /// the render thread, read from the main thread, hence the lock.
    private let statsLock = NSLock()
    private var framesDrawn = 0
    private var longFrames = 0

    func takeFrameStats() -> (drawn: Int, long: Int) {
        statsLock.lock()
        defer { framesDrawn = 0; longFrames = 0; statsLock.unlock() }
        return (framesDrawn, longFrames)
    }

    // MARK: Render loop

    /// Rendering runs on CVDisplayLink's dedicated thread, paced by the
    /// *glasses* display. Two separate problems made the default main-thread
    /// MTKView loop deliver only 40–65 fps of a 120 fps target: the main
    /// thread is busy (UI, timers, IMU at 440 Hz all compete with an 8.3 ms
    /// deadline), and in a mirror set the view's implicit pacing can latch
    /// onto the 60 Hz built-in member instead of the 120 Hz panel.
    private var displayLink: CVDisplayLink?
    private weak var linkedView: MTKView?

    func startRenderLoop(displayID: CGDirectDisplayID, view: MTKView) {
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        linkedView = view

        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &link) == kCVReturnSuccess,
              let link else {
            // No link, no dedicated thread — fall back to MTKView's own loop.
            view.isPaused = false
            return
        }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            // MTKView supports manual drawing from a non-main thread when
            // paused with setNeedsDisplay disabled — which is this.
            self?.linkedView?.draw()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
        displayLink = link
    }

    func stopRenderLoop() {
        if let displayLink { CVDisplayLinkStop(displayLink) }
        displayLink = nil
        linkedView = nil
    }

    deinit { stopRenderLoop() }

    /// Seconds of head-motion prediction. Off by default: prediction fights
    /// latency but amplifies gyroscope noise, and on this hardware the noise
    /// was the more noticeable of the two.
    var lookAhead: Float = 0

    /// Display-side pose smoothing time constant, seconds. Rendering at a
    /// full 120 fps faithfully reproduces the filter's sub-degree tremor —
    /// which the old 45 fps loop had been accidentally hiding — so the pose
    /// used for drawing is eased over the last couple of frames. ~15 ms of
    /// added latency is imperceptible; the shimmer it removes is not.
    var steady: Float = 0.015
    private var steadyHead: simd_quatf?

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
            let formats: [MTLPixelFormat] = [.bgra8Unorm, .bgra8Unorm_srgb]

            func makePair(_ fragment: String,
                          blended: Bool = false) throws -> [MTLRenderPipelineState] {
                try formats.map { format in
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
                    descriptor.fragmentFunction = library.makeFunction(name: fragment)
                    descriptor.colorAttachments[0].pixelFormat = format
                    if blended {
                        // CGImage-sourced textures are premultiplied, hence .one.
                        let blend = descriptor.colorAttachments[0]!
                        blend.isBlendingEnabled = true
                        blend.sourceRGBBlendFactor = .one
                        blend.sourceAlphaBlendFactor = .one
                        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
                        blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                    }
                    return try device.makeRenderPipelineState(descriptor: descriptor)
                }
            }

            pipelines = try makePair("fragmentMain")
            smoothPipelines = try makePair("fragmentSmooth")
            crispPipelines = try makePair("fragmentCrisp")
            // Same vertex path, alpha-blended fragment for the cursor sprite.
            cursorPipelines = try makePair("fragmentCursor", blended: true)

            // Accumulation writes two attachments of the same format.
            accumPipelines = try formats.map { format in
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
                descriptor.fragmentFunction = library.makeFunction(name: "fragmentAccum")
                descriptor.colorAttachments[0].pixelFormat = format
                descriptor.colorAttachments[1].pixelFormat = format
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
        } catch {
            NSLog("Renderer: shader compilation failed — \(error)")
            return nil
        }

        // The screen mesh: a triangle strip of vertical slices, rebuilt each
        // frame because size, distance and curvature are all live-adjustable.
        // Flat screens waste the columns; curved ones need them.
        let meshLength = MemoryLayout<SIMD4<Float>>.stride * Self.meshVertexCount * 2
        // Fullscreen strip for the accumulation pass: NDC positions straight
        // through vertexMain with an identity matrix.
        let fsQuad: [SIMD4<Float>] = [
            SIMD4(-1, -1, 0, 1), SIMD4(0, 1, 0, 0),
            SIMD4( 1, -1, 0, 1), SIMD4(1, 1, 0, 0),
            SIMD4(-1,  1, 0, 1), SIMD4(0, 0, 0, 0),
            SIMD4( 1,  1, 0, 1), SIMD4(1, 0, 0, 0),
        ]
        guard let buffer = device.makeBuffer(length: meshLength, options: .storageModeShared),
              let sideRight = device.makeBuffer(length: meshLength, options: .storageModeShared),
              let sideLeft = device.makeBuffer(length: meshLength, options: .storageModeShared),
              let fsBuffer = device.makeBuffer(
                  bytes: fsQuad, length: MemoryLayout<SIMD4<Float>>.stride * fsQuad.count,
                  options: .storageModeShared)
        else { return nil }
        vertexBuffer = buffer
        sideVertexBuffers = [sideRight, sideLeft]
        fsQuadBuffer = fsBuffer

        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Hand a freshly captured frame to the renderer. Safe to call from any queue.
    func submit(frame: CVPixelBuffer) {
        frameLock.lock()
        pendingFrame = frame
        frameLock.unlock()
    }

    /// Same, for a side screen's capture stream (0 right, 1 left).
    func submitSide(_ index: Int, frame: CVPixelBuffer) {
        frameLock.lock()
        pendingSideFrames[index] = frame
        frameLock.unlock()
    }

    /// Rotate `point` about the anchor's vertical axis — how the side screen
    /// swings away from the main one.
    private static func rotateY(_ point: SIMD3<Float>, _ angle: Float) -> SIMD3<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD3(point.x * c + point.z * s, point.y, -point.x * s + point.z * c)
    }

    /// Rotate `point` about the anchor's horizontal axis — how a stacked
    /// side screen swings up or down. Positive lifts the point.
    private static func rotateX(_ point: SIMD3<Float>, _ angle: Float) -> SIMD3<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD3(point.x, point.y * c - point.z * s, point.y * s + point.z * c)
    }

    /// Side-screen swing: azimuth about Y for the beside layouts, elevation
    /// about X for the stacked one. Exactly one is nonzero per side.
    private static func swing(_ point: SIMD3<Float>,
                              azimuth: Float, elevation: Float) -> SIMD3<Float> {
        if elevation != 0 { return rotateX(point, elevation) }
        if azimuth != 0 { return rotateY(point, azimuth) }
        return point
    }

    /// Fill a mesh buffer with the screen surface, optionally swung by
    /// `azimuth` radians about the vertical axis or `elevation` about the
    /// horizontal one.
    private func fillMesh(_ buffer: MTLBuffer, aspect: Float,
                          azimuth: Float, elevation: Float = 0) {
        let mesh = buffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: Self.meshVertexCount * 2)
        for column in 0...Self.meshColumns {
            let u = Float(column) / Float(Self.meshColumns)
            let bottom = Self.swing(screen.surfacePoint(u: u, v: 1, aspect: aspect),
                                    azimuth: azimuth, elevation: elevation)
            let top = Self.swing(screen.surfacePoint(u: u, v: 0, aspect: aspect),
                                 azimuth: azimuth, elevation: elevation)
            let base = column * 4
            mesh[base + 0] = SIMD4(bottom.x, bottom.y, bottom.z, 1)
            mesh[base + 1] = SIMD4(u, 1, 0, 0)
            mesh[base + 2] = SIMD4(top.x, top.y, top.z, 1)
            mesh[base + 3] = SIMD4(u, 0, 0, 0)
        }
    }

    /// How far a side screen's centre swings from the main screen's, radians
    /// about the vertical axis. The caller applies the sign for left/right.
    private func sideAzimuthMagnitude(mainAspect: Float, sideAspect: Float) -> Float {
        let mainHalf = screen.size(aspect: mainAspect).x / (2 * screen.distance)
        let sideHalf = screen.size(aspect: sideAspect).x / (2 * screen.distance)
        return mainHalf + sideHalf + sideGap
    }

    /// Stacked counterpart: the vertical swing between screen centres.
    private func sideElevationMagnitude(mainAspect: Float, sideAspect: Float) -> Float {
        let mainHalf = screen.size(aspect: mainAspect).y / (2 * screen.distance)
        let sideHalf = screen.size(aspect: sideAspect).y / (2 * screen.distance)
        return mainHalf + sideHalf + sideGap
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(now - lastDrawTime)
        lastDrawTime = now
        statsLock.lock()
        framesDrawn += 1
        if dt > 1.5 / Float(targetFPS) { longFrames += 1 }
        statsLock.unlock()

        var head = filter.predictedRelativeOrientation(lookAhead: lookAhead)
        if steady > 0.0005, dt > 0, dt < 0.5, let previous = steadyHead {
            head = simd_slerp(previous, head, min(1, dt / steady)).normalized
        }
        steadyHead = head
        // The peek reads pitch from the unlocked pose — locking pitch means
        // "the screen ignores tilt", not "I can no longer glance at the
        // keyboard".
        let rawHead = head
        if axisLocks.isActive { head = axisLocks.apply(head) }
        screen.update(head: head, dt: dt,
                      rotationRate: simd_length(filter.angularVelocity))

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let texture = prepareTexture(commandBuffer: commandBuffer)

        // Temporal supersampling: retarget the scene pass at the offscreen
        // texture and let the accumulation pass own the drawable. Mono only;
        // when off, everything draws straight to the drawable as before.
        let tssActive = temporalSS && texture != nil
        var sceneTarget: MTLTexture?
        if tssActive {
            ensureTSSResources(size: view.drawableSize,
                               format: drawable.texture.pixelFormat)
            if let scene = sceneTexture {
                descriptor.colorAttachments[0].texture = scene
                sceneTarget = scene
            }
        }
        if sceneTarget == nil { historyValid = false }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        // Head-down peek: fade everything toward black between the start and
        // full angles. Black is what makes the optics see-through, so this
        // must multiply every fragment — desktop, sides, cursor alike.
        var dim: Float = 1
        if headDownPeek {
            let forward = rawHead.act(SIMD3<Float>(0, 0, -1))
            let pitchDown = asin(max(-1, min(1, -forward.y)))
            let start = peekAngle * .pi / 180
            dim = 1 - simd_smoothstep(start, start + 20 * .pi / 180, pitchDown)
        }
        // Pipeline set from the drawable's actual format, never the toggle:
        // the toggle flips on the main thread mid-flight, and a pipeline
        // built for the other format is a validation failure.
        let linearFB = descriptor.colorAttachments[0].texture?.pixelFormat == .bgra8Unorm_srgb
        let fb = linearFB ? 1 : 0

        // tint rgb = per-channel gains (eye-care warmth), a = overall dim
        // (peek); misc.x = sharpen strength. The warmth and fade curves were
        // tuned by eye against gamma-encoded values; in linear light the
        // same multipliers read much stronger, so raise them to 2.2 to keep
        // the approved feel identical in both modes.
        var tint = SIMD4<Float>(1, 1 - 0.18 * eyeCare, 1 - 0.38 * eyeCare, dim)
        if linearFB {
            tint = SIMD4(pow(tint.x, 2.2), pow(tint.y, 2.2),
                         pow(tint.z, 2.2), pow(tint.w, 2.2))
        }
        var params = FragParams(tint: tint, misc: SIMD4<Float>(sharpen, 0, 0, 0))
        encoder.setFragmentBytes(&params, length: MemoryLayout<FragParams>.size, index: 0)

        // tan(fovX/2), tan(fovY/2) — captured for the accumulation pass's
        // direction math, filled in once the projection is derived below.
        var accumTans = SIMD2<Float>(0, 0)

        if let texture {
            let width = Double(view.drawableSize.width)
            let height = Double(view.drawableSize.height)
            let aspect = Float(width / height)

            let contentAspect = Float(texture.width) / Float(texture.height)
            let model = screen.anchorRotation()

            // Rebuild the screen surfaces: alternating bottom/top vertices
            // per column form one triangle strip across each (possibly
            // curved) surface, positions in the anchor's local frame.
            fillMesh(vertexBuffer, aspect: contentAspect, azimuth: 0)

            // Prepare whichever side screens are live this frame. Beside:
            // right hangs at a negative azimuth, left at a positive one.
            // Stacked: index 0 above (positive elevation), index 1 below.
            var sideRender: [(index: Int, texture: MTLTexture, aspect: Float,
                              azimuth: Float, elevation: Float)] = []
            for index in 0..<sideActive.count where sideActive[index] {
                guard let sideTexture = prepareSideTexture(index) else { continue }
                let aspect = Float(sideTexture.width) / Float(sideTexture.height)
                var azimuth: Float = 0
                var elevation: Float = 0
                if sideStacked {
                    let magnitude = sideElevationMagnitude(mainAspect: contentAspect,
                                                           sideAspect: aspect)
                    elevation = index == 0 ? magnitude : -magnitude
                } else {
                    let magnitude = sideAzimuthMagnitude(mainAspect: contentAspect,
                                                         sideAspect: aspect)
                    azimuth = index == 0 ? -magnitude : magnitude
                }
                fillMesh(sideVertexBuffers[index], aspect: aspect,
                         azimuth: azimuth, elevation: elevation)
                sideRender.append((index, sideTexture, aspect, azimuth, elevation))
            }
            cursorLock.lock()
            // Stacked sides sit at no yaw offset, so the shake-warp's
            // "which screen is the head aimed at" test stays main-only there.
            lastAzimuths = [nil, nil]
            if !sideStacked {
                for side in sideRender { lastAzimuths[side.index] = side.azimuth }
            }
            cursorLock.unlock()

            // Convert the quoted diagonal FOV into the vertical one Metal wants.
            let diagonalTangent = tan(Self.diagonalFOV / 2)
            let verticalTangent = diagonalTangent / (1 + aspect * aspect).squareRoot()
            let fovY = 2 * atan(verticalTangent)
            let projection = simd_float4x4.perspective(
                fovYRadians: fovY, aspect: aspect, near: 0.05, far: 100
            )
            accumTans = SIMD2(verticalTangent * aspect, verticalTangent)

            // How many panel pixels the virtual screen actually spans. Compared
            // against the captured width, this is the sharpness budget: below
            // 1.0 the desktop is being squeezed into fewer pixels than it has,
            // and no amount of filtering can put the detail back.
            let extent = screen.size(aspect: contentAspect)
            renderedWidth = Float(width) * extent.x
                / (screen.distance * 2 * tan(fovY / 2) * aspect)

            // The cursor quad sits on whichever surface the mouse is on, at
            // its fractional position — its corners go through the same
            // surface mapping, so it follows curvature and the side swing.
            cursorLock.lock()
            let sprite = cursorTexture
            let spriteFractions = cursorFraction
            let spriteHotspots = cursorHotspotFraction
            cursorLock.unlock()
            var cursorVertices: [SIMD4<Float>]?
            if let position = cursorPosition?(), sprite != nil {
                // On a side surface, the cursor needs that side's geometry;
                // skip drawing entirely if that side is not rendering.
                let side = position.surface > 0
                    ? sideRender.first(where: { $0.index == position.surface - 1 })
                    : nil
                if position.surface == 0 || side != nil {
                    let fraction = spriteFractions[position.surface]
                    let hotspot = spriteHotspots[position.surface]
                    let aspect = side?.aspect ?? contentAspect
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
                        if let side {
                            p = Self.swing(p, azimuth: side.azimuth,
                                           elevation: side.elevation)
                        }
                        p *= 0.995
                        return [SIMD4(p.x, p.y, p.z, 1), SIMD4(uv.x, uv.y, 0, 0)]
                    }
                }
            }

            let view = screen.viewMatrix(head: head)
            var uniforms = projection * view * model
            encoder.setVertexBytes(&uniforms,
                                   length: MemoryLayout<simd_float4x4>.size,
                                   index: 1)

            encoder.setRenderPipelineState(
                antiMoire ? smoothPipelines[fb]
                          : (crisp ? crispPipelines[fb] : pipelines[fb]))
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: Self.meshVertexCount)

            for side in sideRender {
                encoder.setVertexBuffer(sideVertexBuffers[side.index], offset: 0, index: 0)
                encoder.setFragmentTexture(side.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                       vertexCount: Self.meshVertexCount)
            }

            if let cursorVertices, let sprite {
                encoder.setRenderPipelineState(cursorPipelines[fb])
                encoder.setVertexBytes(cursorVertices,
                                       length: MemoryLayout<SIMD4<Float>>.stride * cursorVertices.count,
                                       index: 0)
                encoder.setFragmentTexture(sprite, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        encoder.endEncoding()

        // Accumulation: blend the fresh scene with the reprojected history,
        // writing the drawable and the new history in one MRT pass.
        if let scene = sceneTarget {
            let cur = 1 - historyIndex
            let accumDescriptor = MTLRenderPassDescriptor()
            accumDescriptor.colorAttachments[0].texture = drawable.texture
            accumDescriptor.colorAttachments[0].loadAction = .dontCare
            accumDescriptor.colorAttachments[0].storeAction = .store
            accumDescriptor.colorAttachments[1].texture = historyTextures[cur]
            accumDescriptor.colorAttachments[1].loadAction = .dontCare
            accumDescriptor.colorAttachments[1].storeAction = .store
            if let accum = commandBuffer.makeRenderCommandEncoder(descriptor: accumDescriptor) {
                let fbIndex = drawable.texture.pixelFormat == .bgra8Unorm_srgb ? 1 : 0
                accum.setRenderPipelineState(accumPipelines[fbIndex])
                var identity = matrix_identity_float4x4
                accum.setVertexBuffer(fsQuadBuffer, offset: 0, index: 0)
                accum.setVertexBytes(&identity, length: MemoryLayout<simd_float4x4>.size,
                                     index: 1)
                // d_prev = R(prevHead⁻¹ · head) · d_cur — rotation only, so
                // the reprojection is exact for everything at any distance.
                let delta = simd_float3x3((prevRenderHead.inverse * head).normalized)
                var accumParams = AccumParamsCPU(
                    reproj0: SIMD4(delta.columns.0, 0),
                    reproj1: SIMD4(delta.columns.1, 0),
                    reproj2: SIMD4(delta.columns.2, 0),
                    info: SIMD4(accumTans.x, accumTans.y,
                                historyValid ? temporalAlpha : 0, 0)
                )
                accum.setFragmentBytes(&accumParams,
                                       length: MemoryLayout<AccumParamsCPU>.size, index: 0)
                accum.setFragmentTexture(scene, index: 0)
                accum.setFragmentTexture(historyTextures[historyIndex], index: 1)
                accum.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                accum.endEncoding()
                historyIndex = cur
                historyValid = true
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        prevRenderHead = head
    }

    /// CPU mirror of the shader's AccumParams.
    private struct AccumParamsCPU {
        var reproj0: SIMD4<Float>
        var reproj1: SIMD4<Float>
        var reproj2: SIMD4<Float>
        var info: SIMD4<Float>
    }

    /// (Re)create the offscreen scene and history textures to match the
    /// drawable. Any change invalidates the history.
    private func ensureTSSResources(size: CGSize, format: MTLPixelFormat) {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return }
        if let scene = sceneTexture, scene.width == width, scene.height == height,
           scene.pixelFormat == format { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        sceneTexture = device.makeTexture(descriptor: descriptor)
        historyTextures = [device.makeTexture(descriptor: descriptor),
                           device.makeTexture(descriptor: descriptor)]
        historyValid = false
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
            // The sRGB view is what makes linear-light real: texels decode
            // to linear *before* the bilinear weights are applied.
            linearLight ? .bgra8Unorm_srgb : .bgra8Unorm, width, height, 0, &wrapped
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
    private func prepareSideTexture(_ index: Int) -> MTLTexture? {
        frameLock.lock()
        let frame = pendingSideFrames[index]
        frameLock.unlock()

        let previous = currentSideTextures[index].flatMap { CVMetalTextureGetTexture($0) }
        guard let frame, let textureCache else { return previous }

        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, frame, nil,
            linearLight ? .bgra8Unorm_srgb : .bgra8Unorm,
            CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), 0, &wrapped
        )
        guard status == kCVReturnSuccess,
              let wrapped,
              let source = CVMetalTextureGetTexture(wrapped)
        else { return previous }
        currentSideTextures[index] = wrapped
        return source
    }
}
