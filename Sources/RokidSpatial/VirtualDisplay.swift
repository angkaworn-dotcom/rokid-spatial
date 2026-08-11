// A display that exists only to be looked at through the glasses.
//
// The alternative — capturing the built-in screen — throws away most of the
// image before it reaches your eye. The desktop is 1680 points wide; the
// virtual screen occupies roughly 1235 panel pixels; text therefore arrives at
// about 73% of the size it was drawn for, and no filtering can put back detail
// that was discarded during downscaling. Sizing a display to match what the
// glasses can actually resolve means macOS renders text at native size and it
// lands one-to-one on the panel.
//
// It also removes a whole class of failure. Nothing needs to be captured from
// the built-in display, so it never has to be un-mirrored, rearranged, or
// touched at all.

import Foundation
import CoreGraphics
import CGVirtualDisplayShim

final class VirtualDisplay {
    private(set) var displayID: CGDirectDisplayID?
    private var display: CGVirtualDisplay?

    enum VirtualDisplayError: Error, CustomStringConvertible {
        case unavailable
        case creationFailed
        case settingsRejected

        var description: String {
            switch self {
            case .unavailable:
                return "This macOS build does not expose CGVirtualDisplay. "
                    + "Virtual display mode is unavailable; capture the built-in screen instead."
            case .creationFailed:
                return "Could not create the virtual display."
            case .settingsRejected:
                return "The virtual display rejected the requested mode."
            }
        }
    }

    /// True if this macOS still ships the private classes we depend on.
    static var isSupported: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
    }

    /// Create a display of `width` × `height` points.
    ///
    /// `hiDPI` asks macOS to treat it as a Retina display, backing each point
    /// with two pixels. That is worth having when the virtual screen is
    /// rendered larger than the display's point size, and wasteful otherwise.
    ///
    /// `identity` must be unique among displays that exist at the same time —
    /// the window server rejects a second display with the same serial. Keep
    /// it stable per role so macOS remembers each display's arrangement.
    func create(width: Int, height: Int, hiDPI: Bool, refreshRate: Double = 60,
                identity: UInt32 = 1) throws {
        guard Self.isSupported else { throw VirtualDisplayError.unavailable }
        destroy()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue(label: "com.rokidspatial.virtualdisplay")
        descriptor.name = "Rokid Spatial"
        descriptor.maxPixelsWide = UInt32(width * (hiDPI ? 2 : 1))
        descriptor.maxPixelsHigh = UInt32(height * (hiDPI ? 2 : 1))
        // Physical size only affects the DPI macOS reports. Roughly 100 DPI
        // keeps it from deciding this is a television and scaling accordingly.
        descriptor.sizeInMillimeters = CGSize(
            width: Double(width) * 0.254,
            height: Double(height) * 0.254
        )
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = identity

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(width), height: UInt(height),
                                 refreshRate: refreshRate)
        ]
        guard display.apply(settings) else {
            throw VirtualDisplayError.settingsRejected
        }

        self.display = display
        self.displayID = display.displayID
    }

    /// Releasing the object is what tears the display down; macOS moves any
    /// windows that were on it back to a real screen.
    func destroy() {
        display = nil
        displayID = nil
    }

    deinit { destroy() }
}
