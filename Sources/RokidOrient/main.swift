// rokid-orient — live head-orientation readout.
//
// Two jobs. First, prove the IMU → fusion path actually tracks the head.
// Second, work out which device axis is which: gravity tells us where "up" is,
// so yaw is unambiguous, but nothing in the packet says which of the remaining
// axes points forward versus right. The per-axis columns below answer that
// empirically — turn your head one way at a time and watch which one moves.

import Foundation
import RokidKit
import simd

let filter = OrientationFilter()
var sampleCount = 0
var lastPrint = Date.distantPast
var startTime = Date()

let imu = RokidIMU { sample in
    filter.update(sample)
    sampleCount += 1

    guard Date().timeIntervalSince(lastPrint) >= 0.1 else { return }
    lastPrint = Date()

    let q = filter.relativeOrientation
    // Small-angle read-off of the rotation about each device axis. Exact for
    // the modest angles a head reaches, and it makes the axis mapping obvious.
    let perAxis = q.imag * 2 * 180 / .pi
    let bias = filter.gyroBias * 180 / .pi

    let flags = [
        filter.isStationary ? "still" : "     ",
        sample.worn ? "worn" : "    ",
    ].joined(separator: " ")

    print(String(
        format: "yaw %+7.2f°  |  axisX %+7.2f°  axisY %+7.2f°  axisZ %+7.2f°  |  bias(%+6.3f %+6.3f %+6.3f)°/s  %@",
        filter.yawDegrees,
        perAxis.x, perAxis.y, perAxis.z,
        bias.x, bias.y, bias.z,
        flags
    ))
}

do {
    try imu.start()
} catch {
    print("✗ \(error)")
    exit(1)
}

// Calibrate the gyroscope bias first — this only works if the glasses are
// sitting still — then treat wherever they point as zero.
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    filter.beginCalibration(seconds: 6)
    print("--- calibrating: keep the glasses completely still ---")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
    filter.recenter()
    let b = filter.gyroBias * 180 / .pi
    print(String(format: "--- calibrated, bias (%+.4f %+.4f %+.4f) deg/s; recentred ---",
                 b.x, b.y, b.z))
}

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    let elapsed = Date().timeIntervalSince(startTime)
    print(String(format: "\n\n%d samples in %.1fs (%.0f Hz)",
                 sampleCount, elapsed, Double(sampleCount) / elapsed))
    exit(0)
}
sigint.resume()
signal(SIGINT, SIG_IGN)

print("rokid-orient — Ctrl-C to stop\n")
startTime = Date()
CFRunLoopRun()
