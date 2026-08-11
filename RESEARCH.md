# Borrowable techniques from neighbouring projects

Findings from reading `wheaney/XRLinuxDriver` and `wheaney/breezy-desktop`
(sombrero shader), recorded so they survive between sessions. Clones live in
`~/Documents/XRLinuxDriver` and `~/Documents/breezy-desktop`.

## Look-ahead, done the way that does not jitter

Status: **tried and rejected** — a faithful port lives on the
`breezy-lookahead` branch and the user judged it "กระตุกไม่นิ่งเลย"
(stuttery, not steady), consistent with every earlier prediction attempt on
this hardware. Likely root cause: breezy differentiates *hardware-fused*
50 Hz pose snapshots that are heavily smoothed on-device, while our software
fusion at 440 Hz keeps more high-frequency content, so even pose-differenced
velocity carries jitter that a ~25 ms extrapolation amplifies. Any future
attempt should start from much heavier velocity smoothing (τ ≥ 100 ms) or a
constant-velocity Kalman state, not from re-porting the shader math — the
port itself is done and correct on the branch (two MVPs blended per vertex
for the 8 ms scanline ramp, cursor pinned to its own scanline).

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

Status: **shipped and confirmed working** (`RokidKit/TapDetector.swift`,
toggle in More). Ported from `XRLinuxDriver/src/multitap.c` with two changes
the real hardware demanded, both found by logging peak values live:

- **The 25 ms derivative window had to shrink to 5 ms.** A tap's gyro spike
  lasts a few samples at 440 Hz; the long window averaged real taps down to
  ~270 °/s² — 7× under the threshold — while a 5 ms window keeps them at
  4,300–13,900 against ≤1,816 for vigorous head shakes and ≤700 for normal
  wear. Threshold set to 2,500.
- **An accelerometer gate was added** (Δ|accel| > 3 m/s² between consecutive
  samples). Taps measured 8–44; head shakes ≤1.5. A head movement now has to
  pass two independent physical tests to fake a tap.

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
