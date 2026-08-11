// Reads the Rokid Max IMU stream off the vendor HID interface.
//
// Packet layout is documented in PROTOCOL.md. The short version: report 17
// arrives at ~440 Hz carrying a nanosecond timestamp followed by three float
// triples (accelerometer, gyroscope, magnetometer). IOKit leaves the report-ID
// byte in place, so every offset here is absolute within the 64-byte buffer.

import Foundation
import IOKit
import IOKit.hid
import simd

public struct IMUSample: Sendable {
    /// Nanoseconds since the glasses powered on.
    public let timestamp: UInt64
    /// Acceleration in m/s², device frame.
    public let accel: SIMD3<Float>
    /// Angular velocity in rad/s, device frame.
    public let gyro: SIMD3<Float>
    /// Magnetic field in µT, device frame. Unreliable indoors.
    public let mag: SIMD3<Float>
    /// True while the proximity sensor says the glasses are being worn.
    public let worn: Bool
}

public enum RokidIMUError: Error, CustomStringConvertible {
    case managerOpenFailed(IOReturn)
    case deviceNotFound

    public var description: String {
        switch self {
        case .managerOpenFailed(let r):
            return "IOHIDManagerOpen failed: 0x\(String(format: "%08x", r))"
        case .deviceNotFound:
            return "no Rokid Max found (VID 0x04D2, PID 0x162F) — is it plugged in?"
        }
    }
}

public final class RokidIMU {
    public static let vendorID = 0x04D2
    public static let productID = 0x162F

    private static let reportSize = 64
    private static let expectedReportID: UInt32 = 17

    // Absolute byte offsets within the report buffer, report-ID byte included.
    private static let offTimestamp = 1
    private static let offAccel = 9
    private static let offGyro = 21
    private static let offMag = 33
    private static let offProxy = 46

    private var manager: IOHIDManager?
    private var buffer: UnsafeMutablePointer<UInt8>?
    private let onSample: (IMUSample) -> Void

    /// `onSample` is invoked on whichever run loop `start(on:)` was given.
    public init(onSample: @escaping (IMUSample) -> Void) {
        self.onSample = onSample
    }

    deinit {
        stop()
    }

    public func start(on runLoop: CFRunLoop = CFRunLoopGetCurrent()) throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<RokidIMU>.fromOpaque(context)
                .takeUnretainedValue()
                .attach(to: device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw RokidIMUError.managerOpenFailed(result)
        }
    }

    public func stop() {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        buffer?.deallocate()
        buffer = nil
    }

    private func attach(to device: IOHIDDevice) {
        // One buffer for the lifetime of the connection; IOKit writes into it
        // directly and hands it back with each callback.
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportSize)
        buffer.initialize(repeating: 0, count: Self.reportSize)
        self.buffer = buffer

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, Self.reportSize,
            { context, _, _, _, reportID, report, reportLength in
                guard let context else { return }
                Unmanaged<RokidIMU>.fromOpaque(context)
                    .takeUnretainedValue()
                    .handle(reportID: reportID, report: report, length: Int(reportLength))
            },
            context
        )
    }

    private func handle(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard reportID == Self.expectedReportID, length >= Self.offProxy + 1 else { return }

        let sample = IMUSample(
            timestamp: Self.u64(report, Self.offTimestamp),
            accel: Self.vec3(report, Self.offAccel),
            gyro: Self.vec3(report, Self.offGyro),
            mag: Self.vec3(report, Self.offMag),
            worn: report[Self.offProxy] != 0
        )
        onSample(sample)
    }

    // MARK: - Little-endian readers

    private static func u64(_ b: UnsafeMutablePointer<UInt8>, _ off: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[off + i]) << (8 * i) }
        return v
    }

    private static func f32(_ b: UnsafeMutablePointer<UInt8>, _ off: Int) -> Float {
        var raw: UInt32 = 0
        for i in 0..<4 { raw |= UInt32(b[off + i]) << (8 * i) }
        return Float(bitPattern: raw)
    }

    private static func vec3(_ b: UnsafeMutablePointer<UInt8>, _ off: Int) -> SIMD3<Float> {
        SIMD3(f32(b, off), f32(b, off + 4), f32(b, off + 8))
    }
}
