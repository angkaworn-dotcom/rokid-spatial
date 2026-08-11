// Built-in panel brightness via the private DisplayServices framework.
//
// There is no public brightness API on Apple Silicon. This is the same route
// the well-known `brightness` CLI takes, resolved with dlsym so a future
// macOS quietly removing the symbols degrades to "does nothing" instead of a
// crash. It exists solely for glasses-only mode's screen-off behaviour, and
// failure is harmless — the hardware brightness keys always work.

import CoreGraphics
import Darwin

enum BuiltinBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )

    private static let getFunction: GetFunction? = {
        guard let handle, let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetFunction.self)
    }()

    private static let setFunction: SetFunction? = {
        guard let handle, let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetFunction.self)
    }()

    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let getFunction else { return nil }
        var value: Float = 0
        return getFunction(display, &value) == 0 ? value : nil
    }

    @discardableResult
    static func set(_ display: CGDirectDisplayID, to value: Float) -> Bool {
        guard let setFunction else { return false }
        return setFunction(display, value) == 0
    }
}
