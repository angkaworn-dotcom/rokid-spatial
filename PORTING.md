# Porting to Windows

Everything here is untested — it was written on a Mac with no Windows machine
to try it on. Treat it as a map, not a guarantee.

## What ports unchanged

`Sources/RokidKit/Fusion.swift` and `Sources/RokidKit/VirtualScreen.swift`
depend on nothing but Foundation and `simd`. Swift on Windows ships `simd`
via swift-numerics-adjacent shims, but the safest move is to swap the handful
of quaternion and matrix operations for a small local implementation — there
are maybe forty lines of real maths between the two files, and doing so drops
the last platform dependency.

The packet layout in [PROTOCOL.md](PROTOCOL.md) is a property of the hardware
and applies identically.

## What has to be rewritten

| macOS | Windows equivalent | Difficulty |
|---|---|---|
| `IOHIDManager` | `hid.dll` — `HidD_GetHidGuid`, `SetupDiEnumDeviceInterfaces`, `ReadFile` on the device handle | easy |
| `libusb` control transfers | **see below** | hard |
| `ScreenCaptureKit` | Windows Graphics Capture (`Direct3D11CaptureFramePool`) | moderate |
| `Metal` | D3D11 or D3D12 | moderate, mechanical |
| `AppKit` / `SwiftUI` | Win32, WinUI 3, or a cross-platform toolkit | moderate |
| `CGConfigureDisplayMirrorOfDisplay` | `ChangeDisplaySettingsEx` with `CDS_*` flags | moderate |
| Carbon `RegisterEventHotKey` | `RegisterHotKey` | easy |

## The hard part: SBS mode on Windows

Reading the IMU is straightforward — Windows' HID class driver exposes input
reports through `ReadFile`, and no driver replacement is needed for that.

Setting the display mode is the problem. It needs a **vendor control transfer
on the device**, and Windows' HID class driver owns the device exclusively.
`hid.dll` offers no path to arbitrary control transfers. The usual workarounds
are all unattractive:

1. **Replace the driver with WinUSB via Zadig.** Works, but it unbinds the
   HID interface, so the OS stops treating the glasses as a HID device and any
   other Rokid software breaks. It is also a per-machine manual step involving
   an unsigned-driver workflow.
2. **Write a filter driver.** Correct, and requires a signed kernel driver.
3. **Skip it.** Run at 1920×1080 @ 60 Hz in 2D and render monocularly.

Option 3 is the honest default for a first Windows release: head tracking,
follow mode, and adjustable screen size all still work. Only stereo depth and
the 90 Hz mode are lost, and those are the least essential features.

Worth checking before committing to any of this: whether Rokid's own Windows
software already sets the mode. If it does, it can be used to switch into SBS
once, and this app only has to render.

## Suggested order

1. HID reader on Windows, verified against `rokid-probe`'s output format
2. Fusion and virtual-screen code moved to a platform-free module
3. D3D11 renderer with Windows Graphics Capture, 2D mode only
4. Hotkeys and a minimal settings window
5. Only then decide whether SBS is worth the driver problem
