// Reads and sets the glasses' display mode over USB.
//
// macOS binds the HID interface to Apple's AppleUserUSBHostHIDDevice, so an
// interface claim would be refused — but these are device-recipient vendor
// requests, and a device-level libusb open is permitted. No kext, no root.
//
// Two details are easy to get wrong and both fail as a *timeout* rather than a
// stall, which looks indistinguishable from a permissions problem: wIndex must
// be 0x1, and the OUT request carries a one-byte payload, not a zero-length one.

import Foundation
import CLibUSB

public enum DisplayMode: UInt16, CaseIterable, CustomStringConvertible {
    case sameOnBoth = 0
    case stereo = 1
    case halfSBS = 2
    case highRefreshRate = 3
    case highRefreshRateSBS = 4

    public var description: String {
        switch self {
        case .sameOnBoth: return "2D (same image both eyes) — 1920×1080 @ 60 Hz"
        case .stereo: return "stereo"
        case .halfSBS: return "half side-by-side"
        case .highRefreshRate: return "high refresh rate"
        case .highRefreshRateSBS: return "high refresh rate + SBS — 3840×1200 @ 90 Hz"
        }
    }

    /// `halfSBS` can be reported by the glasses but not selected.
    public var isSettable: Bool { self != .halfSBS }
}

public enum DisplayControlError: Error, CustomStringConvertible {
    case initFailed
    case deviceNotFound
    case transferFailed(String, Int32)
    case notSettable(DisplayMode)

    public var description: String {
        switch self {
        case .initFailed:
            return "libusb_init failed"
        case .deviceNotFound:
            return "no Rokid Max found (VID 0x04D2, PID 0x162F) — is it plugged in?"
        case .transferFailed(let what, let code):
            let message = String(cString: libusb_strerror(code))
            return "\(what) failed: \(message) (\(code))"
        case .notSettable(let mode):
            return "\(mode) cannot be set, only reported"
        }
    }
}

public enum RokidDisplay {
    private static let vendorID: UInt16 = 0x04D2
    private static let productID: UInt16 = 0x162F
    private static let timeoutMs: UInt32 = 1000

    private static let requestSet: UInt8 = 0x01
    private static let requestQuery: UInt8 = 0x81
    private static let wIndex: UInt16 = 0x1

    private static var typeIn: UInt8 {
        UInt8(LIBUSB_ENDPOINT_IN.rawValue) |
        UInt8(LIBUSB_REQUEST_TYPE_VENDOR.rawValue) |
        UInt8(LIBUSB_RECIPIENT_DEVICE.rawValue)
    }
    private static var typeOut: UInt8 {
        UInt8(LIBUSB_ENDPOINT_OUT.rawValue) |
        UInt8(LIBUSB_REQUEST_TYPE_VENDOR.rawValue) |
        UInt8(LIBUSB_RECIPIENT_DEVICE.rawValue)
    }

    /// Opens the glasses, runs `body`, and always closes them again.
    private static func withDevice<T>(
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var context: OpaquePointer?
        guard libusb_init(&context) == 0 else { throw DisplayControlError.initFailed }
        defer { libusb_exit(context) }

        guard let handle = libusb_open_device_with_vid_pid(context, vendorID, productID) else {
            throw DisplayControlError.deviceNotFound
        }
        defer { libusb_close(handle) }

        return try body(handle)
    }

    /// The serial number, read over the control channel. Useful as a
    /// zero-risk check that the channel works before changing anything.
    public static func serial() throws -> String {
        try withDevice { handle in
            var buffer = [UInt8](repeating: 0, count: 0x40)
            let rc = libusb_control_transfer(
                handle, typeIn, requestQuery, 0x100, 0,
                &buffer, UInt16(buffer.count), timeoutMs
            )
            guard rc >= 0 else { throw DisplayControlError.transferFailed("serial read", rc) }
            return String(cString: buffer)
        }
    }

    public static func currentMode() throws -> DisplayMode {
        try withDevice { handle in
            var buffer = [UInt8](repeating: 0, count: 0x40)
            let rc = libusb_control_transfer(
                handle, typeIn, requestQuery, 0x0, wIndex,
                &buffer, UInt16(buffer.count), timeoutMs
            )
            guard rc >= 0 else { throw DisplayControlError.transferFailed("mode read", rc) }
            return DisplayMode(rawValue: UInt16(buffer[1])) ?? .highRefreshRate
        }
    }

    @discardableResult
    public static func setMode(_ mode: DisplayMode) throws -> DisplayMode {
        guard mode.isSettable else { throw DisplayControlError.notSettable(mode) }
        return try withDevice { handle in
            var payload: [UInt8] = [0]
            let rc = libusb_control_transfer(
                handle, typeOut, requestSet, mode.rawValue, wIndex,
                &payload, UInt16(payload.count), timeoutMs
            )
            guard rc >= 0 else { throw DisplayControlError.transferFailed("mode write", rc) }
            return mode
        }
    }
}
