// RokidProbe — reverse-engineering probe for the Rokid Max IMU stream.
//
// Goal: prove we can open the glasses' vendor HID interface, receive input
// reports, and locate the accelerometer / gyroscope / magnetometer vectors
// inside them. Everything downstream (fusion, renderer) depends on this.
//
// Expected layout, per ar-drivers-rs (Linux/libusb), for report ID 17:
//     u8 type | u64 timestamp | f32[3] accel | f32[3] gyro | f32[3] mag | u8 keys | u8 proxy
// IOKit may or may not strip the leading report-ID byte, so rather than trust
// a fixed offset we scan the buffer for a float triple whose magnitude looks
// like gravity. Sitting still, exactly one offset should light up at ~9.8.

import Foundation
import IOKit
import IOKit.hid

let kVendorID = 0x04D2   // Rokid Corporation Ltd.
let kProductID = 0x162F  // Rokid Max
let kReportSize = 64

// MARK: - Byte helpers

func f32(_ b: UnsafeMutablePointer<UInt8>, _ off: Int) -> Float {
    var raw: UInt32 = 0
    for i in 0..<4 { raw |= UInt32(b[off + i]) << (8 * i) }  // little-endian
    return Float(bitPattern: raw)
}

func vec3(_ b: UnsafeMutablePointer<UInt8>, _ off: Int) -> (Float, Float, Float) {
    (f32(b, off), f32(b, off + 4), f32(b, off + 8))
}

func mag(_ v: (Float, Float, Float)) -> Float {
    (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
}

func hex(_ b: UnsafeMutablePointer<UInt8>, _ len: Int) -> String {
    (0..<len).map { String(format: "%02x", b[$0]) }.joined()
}

/// A float triple is "plausible sensor data" if every component is finite and
/// within a sane physical range. Filters out garbage that happens to decode.
func plausible(_ v: (Float, Float, Float), limit: Float) -> Bool {
    for c in [v.0, v.1, v.2] {
        if !c.isFinite { return false }
        if abs(c) > limit { return false }
    }
    return true
}

// MARK: - State

var reportCounts: [UInt32: Int] = [:]
var dumpedPerID: [UInt32: Int] = [:]
var gravityHits: [UInt32: [Int: Int]] = [:]  // reportID -> offset -> hit count
var lastPrint = Date.distantPast
var startTime = Date()

let kDumpCount = 3          // raw hex dumps to print per report ID
let kPrintInterval = 0.25   // seconds between live decode lines

// MARK: - Input report callback

func onReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    let len = Int(reportLength)
    guard len > 0 else { return }

    reportCounts[reportID, default: 0] += 1

    // Print the first few raw reports of each ID so we can eyeball the layout.
    let dumped = dumpedPerID[reportID, default: 0]
    if dumped < kDumpCount {
        dumpedPerID[reportID] = dumped + 1
        print("[raw] id=\(reportID) len=\(len) \(hex(report, len))")
    }

    // Scan every 4-byte-aligned offset for a gravity-looking float triple.
    var offset = 0
    while offset + 12 <= len {
        let v = vec3(report, offset)
        if plausible(v, limit: 200), mag(v) > 9.0, mag(v) < 10.6 {
            gravityHits[reportID, default: [:]][offset, default: 0] += 1
        }
        offset += 1
    }

    // Live decode using whichever offset has the most gravity hits so far.
    guard Date().timeIntervalSince(lastPrint) >= kPrintInterval else { return }
    guard let best = gravityHits[reportID]?.max(by: { $0.value < $1.value })?.key else { return }
    lastPrint = Date()

    let accel = vec3(report, best)
    let gyro = vec3(report, best + 12)
    let magn = vec3(report, best + 24)

    print(String(
        format: "[id=%2d @%2d] accel(%+7.3f %+7.3f %+7.3f)|%5.2f|  gyro(%+7.3f %+7.3f %+7.3f)  mag(%+8.2f %+8.2f %+8.2f)",
        reportID, best,
        accel.0, accel.1, accel.2, mag(accel),
        gyro.0, gyro.1, gyro.2,
        magn.0, magn.1, magn.2
    ))
}

// MARK: - Device setup

func onDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? "?"
    print("✓ matched: \(product)  serial=\(serial)")

    // Buffer must outlive the callback registration — intentionally never freed.
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: kReportSize)
    buffer.initialize(repeating: 0, count: kReportSize)

    IOHIDDeviceRegisterInputReportCallback(
        device, buffer, kReportSize, onReport, nil
    )
    print("✓ listening for input reports…\n")
}

// MARK: - Main

print("RokidProbe — looking for VID=0x\(String(kVendorID, radix: 16)) PID=0x\(String(kProductID, radix: 16))")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matching: [String: Any] = [
    kIOHIDVendorIDKey as String: kVendorID,
    kIOHIDProductIDKey as String: kProductID,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(manager, onDeviceMatched, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    print("✗ IOHIDManagerOpen failed: 0x\(String(format: "%08x", openResult))")
    print("  If this is 0xe00002c2 (not permitted), grant Input Monitoring to your terminal in")
    print("  System Settings → Privacy & Security → Input Monitoring.")
    exit(1)
}

// Summarise on Ctrl-C.
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    let elapsed = Date().timeIntervalSince(startTime)
    print("\n\n=== summary after \(String(format: "%.1f", elapsed))s ===")
    for (id, count) in reportCounts.sorted(by: { $0.key < $1.key }) {
        let rate = Double(count) / elapsed
        print(String(format: "report id=%2d  count=%6d  (%.0f Hz)", id, count, rate))
        if let hits = gravityHits[id]?.sorted(by: { $0.value > $1.value }).prefix(3), !hits.isEmpty {
            for (off, n) in hits {
                print("    gravity-like float triple at offset \(off)  (\(n) hits)")
            }
        } else {
            print("    no gravity-like float triple found")
        }
    }
    exit(0)
}
sigintSource.resume()
signal(SIGINT, SIG_IGN)

print("(hold the glasses still — Ctrl-C to stop and print a summary)\n")
startTime = Date()
CFRunLoopRun()
