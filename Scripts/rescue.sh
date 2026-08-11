#!/bin/bash
# Last resort. Kills the app and puts the glasses back to plain 2D.
#
# Written to be runnable blind — if the overlay is covering everything, you
# cannot read the screen, so this must work with no output to look at and no
# window to click. Type it into a terminal and press Return.
#
# The overlay window dies with the process, so killing the app is what
# actually gives you the screen back. Resetting the panel mode afterwards is
# what stops the glasses showing a stretched or side-by-side image.

cd "$(dirname "$0")/.."

killall -9 RokidSpatial 2>/dev/null
pkill -9 -f RokidSpatial 2>/dev/null

sleep 1

# Mode 0: same image to both eyes, 1920×1080 @ 60 Hz. Always safe.
if [ -x .build/rokid-display-mode ]; then
    .build/rokid-display-mode set 0
else
    echo "rokid-display-mode not built — unplug and replug the glasses instead"
fi

# The mode change makes the display re-enumerate, and macOS answers that by
# re-applying its remembered arrangement — mirrored, with the glasses as
# master and the built-in display dark. There is no way to make it forget
# (.permanently does not survive the next re-enumeration; verified), and a
# re-enumeration produces up to two re-apply events, the second as late as
# ~10 s after the mode command. So: watch for up to 30 s, un-mirror every time
# it comes back, declare victory only after 8 quiet seconds, then hand the
# menu bar back to the built-in screen.
swift - <<'EOF' 2>/dev/null
import CoreGraphics
import Foundation

func displays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

let deadline = Date().addingTimeInterval(30)
var quietSince = Date()
while Date() < deadline {
    let ids = displays()
    if ids.contains(where: { CGDisplayIsInMirrorSet($0) != 0 }) {
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        for id in ids {
            CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        }
        CGCompleteDisplayConfiguration(config, .forSession)
        quietSince = Date()
    } else if Date().timeIntervalSince(quietSince) >= 8 {
        break
    }
    Thread.sleep(forTimeInterval: 0.25)
}

let ids = displays()
if let builtin = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) {
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    CGConfigureDisplayOrigin(config, builtin, 0, 0)
    var x = Int32(CGDisplayPixelsWide(builtin))
    for id in ids where id != builtin {
        CGConfigureDisplayOrigin(config, id, x, 0)
        x += Int32(CGDisplayPixelsWide(id))
    }
    CGCompleteDisplayConfiguration(config, .forSession)
}
EOF

echo
echo "Rescued. If the glasses still look wrong, unplug and replug them."
echo "Display arrangement and mirroring can be reset in System Settings → Displays."
