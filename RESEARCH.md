# Borrowable techniques from neighbouring projects

Findings from reading `wheaney/XRLinuxDriver` and `wheaney/breezy-desktop`
(sombrero shader), recorded so they survive between sessions. Clones live in
`~/Documents/XRLinuxDriver` and `~/Documents/breezy-desktop`.

## Look-ahead, done the way that does not jitter

Status: **deferred** — at 120 Hz in glasses-only mode the user judged blur
acceptable without it. Revisit if that changes.

Our earlier prediction attempt jittered and was defaulted off. Breezy's does
not, and the differences are exactly the lessons:

1. **Velocity comes from filtered pose snapshots, not raw gyro.** The shader
   receives the two most recent fused orientations with timestamps and
   differentiates those (`rateOfChange(rotated_t0, rotated_t1, dt)`), so the
   prediction inherits the filter's smoothness. Differentiating raw gyro at
   440 Hz is what made ours shake.
2. **Rokid-tuned constants exist** in `XRLinuxDriver/src/devices/rokid.c`:
   `look_ahead = 20.0 ms + 0.6 × frametime`, capped at 40 ms (shader hard cap
   45 ms). At 120 Hz that is ≈25 ms of prediction.
3. **Scanline adjustment: +8 ms × texcoord.y.** The panel scans top to
   bottom, so lower rows display later and need more prediction. This is what
   removes the shear during head turns. Porting it to our single-quad Metal
   renderer means either subdividing the quad into horizontal strips or
   moving the rotation into the fragment shader (sombrero does the latter —
   its whole reprojection is per-pixel).

## Double-tap the glasses to recenter

Status: **candidate, not started.** `XRLinuxDriver/src/multitap.c` (~130
lines) detects taps as spikes in the *derivative* of gyro magnitude over a
25 ms window: state machine IDLE→RISE→FALL→PAUSE, tap duration ≤70 ms, taps
≤750 ms apart, threshold 2000 (deg/s per s). Double-tap = recenter in their
driver. Ports directly onto our 440 Hz IMU callback; needs nothing new from
the hardware.

## Curved display

Status: **candidate.** `Sombrero.frag` has a curved-display branch (lenses
inside a circle of the display's radius) behind a `curved_display` uniform.
Worth a look if very wide/large virtual screens ever feel edge-distorted.

## Looked at and rejected

- Quaternion helpers (`imu.c`) — we already have simd equivalents.
- On-board fusion via Rokid's proprietary SDK (`GAME_ROTATION_EVENT`,
  50 Hz) — the SDK blob is x86-64 Linux only, and our local filter reads raw
  sensors at 440 Hz anyway. Documented in PROTOCOL.md.
- Breezy's smooth-follow — ours is already equivalent (deadzone + settle).
