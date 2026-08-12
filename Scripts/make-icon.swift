// Renders the app icon: a dark squircle, the three-screen wall floating
// above a pair of glasses — the product in one picture. Regenerate with:
//   swift Scripts/make-icon.swift && Scripts/make-iconset.sh
// The committed artifact is Resources/AppIcon.icns; this script only needs
// re-running if the design changes.

import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Big Sur-style squircle with the standard margin.
let inset: CGFloat = 100
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset,
                        width: canvas - 2 * inset, height: canvas - 2 * inset),
    xRadius: 185, yRadius: 185
)
NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.46, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.12, alpha: 1),
])!.draw(in: squircle, angle: -90)

/// A slightly rounded screen, optionally swung about its vertical centre —
/// the wall's side screens get a perspective squeeze instead of a rotation,
/// which reads better at icon sizes.
func drawScreen(centerX: CGFloat, centerY: CGFloat, width: CGFloat,
                height: CGFloat, squeeze: CGFloat, alpha: CGFloat) {
    let w = width * squeeze
    let rect = NSRect(x: centerX - w / 2, y: centerY - height / 2,
                      width: w, height: height)
    let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
    NSColor(calibratedWhite: 1.0, alpha: alpha).setFill()
    path.fill()
}

// The wall: centre screen flanked by two swung sides, hovering where the
// glasses will project it.
drawScreen(centerX: 512, centerY: 640, width: 300, height: 200, squeeze: 1.0, alpha: 0.95)
drawScreen(centerX: 276, centerY: 628, width: 220, height: 176, squeeze: 0.62, alpha: 0.55)
drawScreen(centerX: 748, centerY: 628, width: 220, height: 176, squeeze: 0.62, alpha: 0.55)

// The glasses, drawn as geometry rather than an SF Symbol so the shapes stay
// crisp at every raster size: two lens rects joined by a bridge, temples
// hinted outward.
func lens(centerX: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: centerX - 130, y: 250, width: 260, height: 170),
                 xRadius: 60, yRadius: 60)
}
let lensColor = NSColor(calibratedWhite: 1.0, alpha: 0.98)
let strokeWidth: CGFloat = 34

for centerX: CGFloat in [352, 672] {
    let path = lens(centerX: centerX)
    path.lineWidth = strokeWidth
    lensColor.setStroke()
    path.stroke()
}
// Bridge.
let bridge = NSBezierPath()
bridge.move(to: NSPoint(x: 482, y: 370))
bridge.curve(to: NSPoint(x: 542, y: 370),
             controlPoint1: NSPoint(x: 500, y: 398),
             controlPoint2: NSPoint(x: 524, y: 398))
bridge.lineWidth = strokeWidth
lensColor.setStroke()
bridge.stroke()
// Temples, just a hint outward.
for (fromX, toX): (CGFloat, CGFloat) in [(222, 168), (802, 856)] {
    let temple = NSBezierPath()
    temple.move(to: NSPoint(x: fromX, y: 380))
    temple.line(to: NSPoint(x: toX, y: 402))
    temple.lineWidth = strokeWidth
    temple.lineCapStyle = .round
    temple.stroke()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("could not encode the icon") }
let out = URL(fileURLWithPath: "Resources/AppIcon-1024.png")
try FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try png.write(to: out)
print("wrote \(out.path)")
