// Moves other apps' windows off hidden desktops and back onto the visible
// one. The standalone variants have desktops the user cannot see (the
// glasses' sliver under the overlay, the dark parked built-in), and macOS's
// remembered-arrangement re-applies scatter windows onto them — "everything
// on my screen just disappeared" was the live experience. Repositioning
// another app's window is only possible through the Accessibility API, which
// needs the user's one-time consent (bound to the code signature, so the
// stable dev certificate keeps it across rebuilds).

import AppKit
import ApplicationServices

enum WindowRescue {
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system consent prompt if permission has not been granted.
    /// macOS sends the user to System Settings; nothing else we can do.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Move every sizeable window whose centre lies on one of the `hidden`
    /// display regions into `target` (all rects in the global top-left
    /// coordinate space CGWindowList and AX share). Returns how many moved.
    static func rescueWindows(from hidden: [CGRect], to target: CGRect,
                              log: (String) -> Void) -> Int {
        guard hasPermission, !hidden.isEmpty,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]]
        else { return 0 }

        var moved = 0
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  owner != "Rokid Spatial", owner != "Dock",
                  owner != "Window Server", owner != "Control Centre",
                  owner != "Control Center", owner != "Notification Centre",
                  owner != "Notification Center",
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double,
                  width > 80, height > 80
            else { continue }

            let frame = CGRect(x: x, y: y, width: width, height: height)
            guard hidden.contains(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) })
            else { continue }

            // Find the app's AX window whose position matches the one the
            // window list reported — that is the element we can move.
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString,
                                                &value) == .success,
                  let windows = value as? [AXUIElement]
            else { continue }

            for axWindow in windows {
                var positionValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString,
                                                    &positionValue) == .success,
                      let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID()
                else { continue }
                var position = CGPoint.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
                guard abs(position.x - frame.minX) < 2, abs(position.y - frame.minY) < 2
                else { continue }

                // Centre it on the target, clamped so the title bar stays
                // reachable even for windows larger than the display.
                var newPosition = CGPoint(
                    x: max(target.minX, min(target.midX - frame.width / 2,
                                            target.maxX - min(frame.width, 200))),
                    y: max(target.minY, min(target.midY - frame.height / 2,
                                            target.maxY - 100))
                )
                guard let axPosition = AXValueCreate(.cgPoint, &newPosition) else { continue }
                if AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString,
                                                axPosition) == .success {
                    moved += 1
                    log("rescued a \(owner) window from a hidden desktop")
                }
                break
            }
        }
        return moved
    }
}
