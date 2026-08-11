# Rokid Max — USB protocol notes

Reverse-engineered on macOS 26.6 (Apple M1) against a real Rokid Max,
serial `[serial redacted]`, firmware/version number `512` (0x200).

## Device identity

| | |
|---|---|
| Vendor ID | `0x04D2` ("Rokid Corporation Ltd.") |
| Product ID | `0x162F` ("Rokid Max") |
| Transport | USB HID, `bInterfaceClass = 3` |
| Usage page | `0xFF00` (vendor-defined), usage `0x01` |
| Report interval | 2000 µs (nominal 500 Hz; ~436 Hz observed in practice) |

Because the usage page is vendor-defined rather than a generic-desktop
keyboard/mouse page, macOS hands the device over to `IOHIDManager` without
requiring Input Monitoring consent. No kext, no DriverKit, no root.

## HID report descriptor

Raw descriptor as reported by IOKit:

```
0600ff 0901 a101
  8501 0901 15c5 25ff 7508 953f 9182   ; report 1  — OUTPUT, 63 bytes
  8502 0901 1500 25ff 7508 953f 8182   ; report 2  — INPUT,  63 bytes
  8503 0901 1500 25ff 7508 953f 8182   ; report 3  — INPUT,  63 bytes
  8504 0901 1500 25ff 7508 953f 8182   ; report 4  — INPUT,  63 bytes
  8511 0901 1500 25ff 7508 953f 8182   ; report 17 — INPUT,  63 bytes
c0
```

Report 1 is the only OUTPUT report, so it is the command channel.
Reports 2/3/4 exist but stayed silent for the whole probe run — only
report 17 ever arrived. Feature reports are 1 byte and appear unused.

## Report 17 — combined IMU packet

IOKit does **not** strip the report-ID byte; it arrives as byte 0 of the
buffer *and* separately in the callback's `reportID` argument.

| Offset | Type | Field | Notes |
|---:|---|---|---|
| 0 | u8 | report ID | always `0x11` |
| 1–8 | u64 LE | timestamp | nanoseconds since device boot |
| 9–20 | f32[3] LE | accelerometer | m/s² |
| 21–32 | f32[3] LE | gyroscope | rad/s |
| 33–44 | f32[3] LE | magnetometer | µT |
| 45–47 | u8 | keys / proximity | `0` when idle; proximity = wear detection |
| 48–55 | u64 LE | timestamp #2 | ~10.95 ms earlier than the first |

There is **no quaternion** in the stream — the glasses ship raw sensor
vectors only, so orientation must be derived by our own sensor fusion.

### Locating the fields

Three candidate offsets (5, 9, 13) all yield an acceleration magnitude near
9.8, because consecutive float triples overlap and alias. Offset 9 is the
correct one, and gyroscope is what disambiguates: with the glasses held
still, only `accel@9` leaves `gyro@21 ≈ (0.0025, -0.0029, 0.0013)`. The
alternatives imply a stationary device rotating at 2.27 and 43.2 rad/s
respectively, which is nonsense.

Sample packet (glasses stationary, worn):

```
11 ba8ad99166010000 802262be 63531941 581411c0 9040213b 06a83fbb 88edab3a
   cdcc2cc2 3333a642 000055c2 000000 5d72329166010000 000000503c000000
```

Decodes to:

- timestamp = 1 540 045 245 114 ns (25.7 min uptime)
- accel = (-0.221, 9.583, -2.267) m/s², |a| = 9.85
- gyro = (0.0025, -0.0029, 0.0013) rad/s
- mag = (-43.2, 83.1, -53.25) µT, |m| = 107.7

The magnetometer magnitude is well above Earth's 25–65 µT, so it is either
uncalibrated or picking up local interference. Treat indoor yaw correction
from the magnetometer as unreliable.

## Display mode control

Per `badicsalex/ar-drivers-rs`, display mode is set with a USB **control
transfer**, not a HID report:

- `bmRequestType`: vendor, device recipient
- `bRequest`: `0x1`
- `wValue`:

| value | mode |
|---:|---|
| 0 | same image on both eyes (2D) |
| 1 | stereo |
| 3 | high refresh rate |
| 4 | high refresh rate + side-by-side |

There is a matching **read** request, `bRequest = 0x81`, which is the safest
way to test the channel since it changes nothing:

| bRequest | wValue | wIndex | returns |
|---:|---:|---:|---|
| `0x81` | `0x100` | 0 | serial number string, 64 bytes |
| `0x81` | `0x0` | `0x1` | current mode in byte 1 |

**Confirmed working on macOS.** Two details matter and both fail as a
*timeout* rather than a stall, which is indistinguishable from a permissions
problem at first glance:

- `wIndex` must be `0x1`, not `0`
- the OUT request carries a **1-byte payload**, not a zero-length one

macOS binds the HID *interface* to `AppleUserUSBHostHIDDevice`, but these are
device-recipient requests and `libusb_open_device_with_vid_pid` succeeds, so
no interface claim is needed. No kext, no DriverKit, no root.

### Measured modes

| mode | reported by macOS | per eye | stereo | backing scale |
|---:|---|---|---|---|
| 0 | 1920×1080 @ 60 Hz | 1920×1080 | no | 1.0 |
| **3** | **1920×1200 @ 120 Hz** | 1920×1200 | no | 1.0 |
| 4 | 3840×1200 @ 90 Hz | 1920×1200 | yes | 2.0 |

Enumerating `CGDisplayCopyAllDisplayModes` confirms these are hard limits,
not macOS picking badly: in mode 4 *every* available mode is 90 Hz, and in
mode 3 every one is 120 Hz. The "high refresh rate" name attaches to mode 3;
mode 4's extra "SBS" costs 30 Hz.

So mode 3 beats mode 4 on every axis except stereo, at identical per-eye
resolution. Since stereo disparity at a 2.5 m virtual screen distance is only
about 1.4°, mode 3 at 120 Hz is the better default for a virtual monitor.

Mode 4 also reports a backing scale of 2.0, so macOS presents 3840×1200
pixels as a 1920×600 point space. Mode 3 is 1:1.

### Mirroring is reinstated by a mode change

Changing the panel mode makes the display re-enumerate, and macOS then
restores its remembered arrangement — **including mirroring**. Un-mirroring
before the mode change is silently undone a few seconds later. Set the mode
first, then un-mirror.

### Identifying the display

The glasses report EDID vendor `12372`, model `18259`, serial `0`.
`CGDisplayVendorNumber` is a much more reliable handle than the display's
name: `NSScreen` collapses a mirror set into one entry named after the
*master*, so a name search finds nothing whenever the glasses are the slave.
`NSScreen.screens` is also a main-thread cache and reports stale arrangements
from background threads — use `CGGetOnlineDisplayList` instead.

## Sensor axes

Determined empirically by moving the head one axis at a time and watching
which component of the relative orientation responded (`rokid-orient`):

| Device axis | Meaning | Evidence |
|---|---|---|
| **X** | pitch (nodding) | 16–61° swing while gravity-derived yaw stayed under 3° |
| **Y** | yaw (turning), and "up" | tracked derived yaw to within 1–2% across a 63° turn; also carries the +9.58 m/s² gravity reading |
| **Z** | roll (tilting) | by elimination |

The cross-axis isolation is the reassuring part: nodding moved pitch by 61°
while yaw stayed at 2°, so the fusion is not leaking one axis into another.

## Drift

Pitch and roll do not drift — gravity pins them. Yaw has no such reference, so
it is entirely at the mercy of how well the gyroscope bias is estimated.

Measured yaw drift, glasses stationary:

| bias estimator | drift |
|---|---|
| loose threshold (2.9 °/s), fast adaptation (τ≈0.1 s) | −3.3 °/min |
| strict threshold (0.7 °/s), slow adaptation (τ=20 s) | **−9.8 °/min** |
| explicit calibration, glasses set down for 6 s | **+0.14 °/min** |

The middle row is the instructive one. Tightening the "is it still?" threshold
sounds like the rigorous choice and made things three times *worse*: a worn
head never holds still to 0.7 °/s for a full second, so the estimator never ran
at all and the bias stayed at zero. Raw bias is around 0.2–0.3 °/s, which is
roughly 15 °/min of uncorrected drift.

The first row fails the opposite way. With a 2.9 °/s threshold, any slow
deliberate head turn is quietly absorbed as bias — so when you stop turning,
the screen drifts the other way, and the slower you moved, the worse it is.

What actually works is not a cleverer passive estimator but an explicit
calibration: leave the glasses still for six seconds and learn the bias with a
one-second time constant. That reaches 0.14 °/min, a 24× improvement, which
means an anchored screen moves about 1.4° in ten minutes — imperceptible.
Passive estimation still runs afterwards, at a 20 s time constant, to track
thermal changes.

## On-board sensor fusion (not used)

Rokid's own SDK exposes a `ROTATION_EVENT` and `GAME_ROTATION_EVENT`
delivering `float Q[4]` — a hardware-fused quaternion. `XRLinuxDriver` uses it
for Rokid via `GlassRegisterEventWithSize(handle, GAME_ROTATION_EVENT, 50)`
and `GlassAddFusionEvent(handle, true)`, which is why that project runs its own
AHRS for XREAL but not for Rokid.

This likely explains why input reports 2, 3 and 4 exist but never fire: they
carry event types nothing has subscribed to.

Reaching it means either the proprietary Rokid SDK — a Linux-only `.so` — or
reverse-engineering the USB commands those SDK calls emit. Neither was
necessary here: a calibrated local filter reaches 0.14 °/min, and reading raw
sensors at ~440 Hz gives lower latency than the SDK's 50 Hz rotation stream.

## Optical constants (fixed, not adjustable)

The birdbath optics present a 215" image at 6 m, 50° FOV, 1920×1080 per eye,
with a 0–6.0 diopter myopia adjustment per side. The **focal distance is
fixed in hardware** — no software can change where the eye must focus.
Stereo disparity can change the *perceived* distance, but not the
accommodation demand, which is why SBS mode is a partial fix at best.

## References

- [`badicsalex/ar-drivers-rs`](https://github.com/badicsalex/ar-drivers-rs) — Rust drivers, source of the packet layout and display-mode commands
- [`wheaney/XRLinuxDriver`](https://github.com/wheaney/XRLinuxDriver) — Linux userspace driver for XR glasses
- [`wheaney/breezy-desktop`](https://github.com/wheaney/breezy-desktop) — the Linux XR desktop this project is modelled on
