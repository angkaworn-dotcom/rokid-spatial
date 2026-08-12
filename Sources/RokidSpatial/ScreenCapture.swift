// Captures the desktop display with ScreenCaptureKit.
//
// Our own overlay window is excluded from the capture. Without that the
// glasses would show the desktop containing the glasses' own output, which
// recurses until the frame is mush.

import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on a background queue for every captured frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main queue if the stream dies unexpectedly.
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.rokidspatial.capture", qos: .userInteractive)

    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0

    /// The desktop's width in *points*, not pixels.
    ///
    /// This is what governs perceived sharpness. Text is laid out in points, so
    /// legibility depends on how many panel pixels each point gets — comparing
    /// against the Retina pixel count instead would demand a virtual screen
    /// wider than the panel itself, which is not a target that exists.
    private(set) var pointWidth = 0

    enum CaptureError: Error, CustomStringConvertible {
        case displayNotShareable

        var description: String {
            "ScreenCaptureKit does not list the desktop display as shareable. "
            + "Grant Screen Recording permission in System Settings → Privacy & Security."
        }
    }

    /// `excludingWindowNumber` narrows the self-exclusion to a single window.
    /// Glasses-only mode needs this: it captures the same display the overlay
    /// covers, and excluding the whole app would also hide the settings window
    /// from the one place the user can still see it.
    func start(displayID: CGDirectDisplayID, frameRate: Int,
               excludingWindowNumber: Int? = nil,
               showsCursor: Bool = true) async throws {
        var content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        // The narrow exclusion needs the overlay window in the shareable
        // list, and a window created moments ago may not be enumerated yet.
        // Falling back silently used to exclude the whole app instead — which
        // also erased the settings window from the capture, the one place a
        // glasses-only user can see it ("Settings won't open", seen live).
        // Give enumeration a moment to catch up before accepting that.
        if let number = excludingWindowNumber {
            for _ in 0..<3 where !content.windows.contains(
                where: { $0.windowID == CGWindowID(number) }) {
                try await Task.sleep(nanoseconds: 700_000_000)
                content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
            }
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotShareable
        }

        // Exclude ourselves so the overlay never feeds back into the capture.
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let ourApp = content.applications.first { $0.processID == ourPID }

        let filter: SCContentFilter
        if let number = excludingWindowNumber,
           let overlay = content.windows.first(where: { $0.windowID == CGWindowID(number) }) {
            filter = SCContentFilter(display: display, excludingWindows: [overlay])
        } else {
            if excludingWindowNumber != nil {
                AppLog.append("capture: overlay window never enumerated — "
                    + "excluding the whole app (settings will be invisible)")
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: ourApp.map { [$0] } ?? [],
                exceptingWindows: []
            )
        }

        // Capture at the display's true pixel size so text stays crisp once
        // it is projected, but cap it — beyond this we are paying for detail
        // the 50° field of view cannot resolve anyway.
        let mode = CGDisplayCopyDisplayMode(displayID)
        let nativeWidth = mode?.pixelWidth ?? Int(CGDisplayPixelsWide(displayID))
        let nativeHeight = mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(displayID))
        let capWidth = 3008
        let scale = nativeWidth > capWidth ? Double(capWidth) / Double(nativeWidth) : 1
        pixelWidth = Int(Double(nativeWidth) * scale)
        pixelHeight = Int(Double(nativeHeight) * scale)
        pointWidth = Int(CGDisplayPixelsWide(displayID))

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 4
        config.showsCursor = showsCursor
        config.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // A frame arrives even when nothing changed on screen; those carry a
        // status other than .complete and no usable surface.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        onFrame?(pixelBuffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onStop?(error)
        }
    }
}
