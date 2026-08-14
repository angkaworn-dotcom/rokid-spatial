# Roadmap — what is worth doing next

Written 2026-08-14, after the SpaceWalker harvest and the image-quality
pass. Ranked inside each section by expected payoff per unit of effort.
Perceptual claims here are hypotheses until the user's eyes rule on them —
that is the house rule ([RESEARCH.md](RESEARCH.md) is where verdicts land).

Two axes matter to this user and they are **separate**: image sharpness
and eye comfort. Neither trades against the other. The single most valued
feature shipped so far is the eye-care warmth slider ("แทบหายไปเลย" — the
eye burning almost completely gone).

## Image quality (Mac)

1. **HiDPI supersampled desktop** — 1920×1200 points on a 3840×2400 px
   backing, so macOS renders text at 2× and our Catmull-Rom minifies it
   2:1 onto the panel. **CLOSED 2026-08-15 — rejected by the user before
   a perceptual test.** The plumbing shipped and was removed the same day
   (UI only; the `maxWidth:` capture parameter and the capture-size log
   line remain, `8cb44af`). Grounds: overkill for the daily driver, the
   sixth picker segment overflowed the Settings window, and the
   2nd-desktop mode's arrange-windows-by-hand friction. The fps drop
   initially blamed on it was measured to be build/compile load (see
   RESEARCH.md) — the 2× path never ran. To retry: re-add a
   `r1920x1200hi` case — the capture path is ready, including the trap
   found in advance (the old 3008 px `capWidth` would have silently
   downscaled 3840 back and erased the whole point).
2. **MetalFX Spatial (or FSR/EASU) for magnification** — edge-directed
   upscaling, visibly better than Catmull-Rom when a small virtual
   desktop is blown up onto the panel. Irrelevant at 1:1, so it only
   helps the small 2nd-desktop sizes. MetalFX is in the OS; wiring is
   modest.
3. **RCAS instead of the clamped unsharp mask** — per-pixel adaptive
   sharpening strength. Principled, but the visible delta over the
   current slider is small. Do only if sharpening artefacts ever annoy.
4. **Temporal supersampling, mirror-mode re-test** — rejected at 1:1
   (slightly softer, twice — see RESEARCH.md), but minification flips
   the trade: the same averaging that softened native-scale text
   suppresses aliasing instead. Engine still in the code;
   `defaults write com.rokidspatial.app temporalSS -bool true`.
5. Not worth pursuing: ML super-resolution (not real-time at 60, and it
   invents strokes in text); Lanczos-3 over Catmull-Rom (hair-width gain,
   more ringing). The hard ceiling is the birdbath optics and the 1080p
   panel — no shader crosses it.

## Eye comfort (Mac) — the user's top-valued axis

6. **Night mode: warmth + hardware brightness together.** Eye care today
   only removes blue; burning eyes are also about total light. The
   glasses accept a brightness command over HID (PROTOCOL.md), so one
   "night" control could drive both. Best comfort payoff on the list.
7. **Eye-care hotkey** (e.g. ⌃⌥W cycling 0 → 0.3 → 0.6 → 0) — the
   feature is loved; reaching it should not require the Settings window.
8. **Auto-warmth by clock** — Night-Shift-style schedule, daylight
   neutral, evenings warm.

## Quality of life (Mac)

9. **⌃⌥S Stop/Start toggle** — offered repeatedly for the DRM workflow
   (Stop turns the glasses into a plain mirror for Netflix); one hotkey
   in AppDelegate.
10. **Roll-lock hotkey** — the lock is used on the sofa; a hotkey beats
    opening Settings while lying down.
11. **Auto-start when the glasses are plugged in** — detect enumeration,
    start the session; ends the "plug, then go find the Start button"
    ritual.
12. **Presets** — one-click bundles (Desk: Anchored + sides · Sofa:
    Smooth Follow + roll lock · Lying flat: pitch+yaw+roll locks), each
    a hotkey.
13. **Cinema mode** — PARKED by the user ("เดี๋ยวค่อยทำ"). The crux is
    SCK's inability to capture native fullscreen video; the cheap v1 is
    a preset (big anchored curved screen, sides off). Ask which scope
    when resumed.

## Windows port — the plan (companion to [PORTING.md](PORTING.md))

**Why the port exists:** 120 Hz. The Mac experiments ended with
WindowServer oscillating 60↔149 on its own and no app-side pin
(RESEARCH.md "The direct-scanout instrument"); the decision — made twice
— is that high refresh happens on Windows, where the compositor can be
bypassed outright.

What Windows offers that macOS refused:

- **True direct scanout**: D3D12 + DXGI flip-model with fullscreen
  exclusive (or hardware overlay planes / `IndependentFlip`) puts our
  swapchain straight on the panel — no compositor in the path, which
  also kills the "close every heavy app to keep 60" problem for good.
- **Custom display timing**: CRU-style EDID overrides are the
  community-proven route to clean 120 Hz on this family of glasses
  (user-sourced evidence: Max 1 does clean 120 on PC).
- No Low Power Mode compositing clamp, no remembered-arrangement fights,
  no Dock.

What carries over as-is (deliberately platform-free, `import simd` only):
`Fusion.swift`, `VirtualScreen.swift`, `AxisLocks.swift` — the entire
feel of the product (filter tuning, deadzone/settle, smooth follow,
motion lock, peek geometry) is in those files. Port them first and the
Windows build inherits months of tuning verdicts for free.

Feature parity checklist for a first Windows release, in order:

1. HID IMU reader at 440 Hz (`ReadFile` on the HID handle; verify
   against `rokid-probe` output; PROTOCOL.md applies unchanged).
2. RokidKit maths as a platform-free module (per PORTING.md).
3. D3D11 renderer + Windows Graphics Capture, 2D 60 Hz first — the
   shader set is small and ports mechanically (sharpen, Catmull-Rom,
   linear-light are ~100 lines of HLSL).
4. Hotkeys (`RegisterHotKey`) + minimal settings UI.
5. Eye care + head-down peek + axis locks — trivial once the shader and
   the maths module are up, and they are the loved features.
6. **Then the actual mission: 120 Hz.** Exclusive fullscreen on the
   glasses, CRU timing if the default EDID misbehaves, measure
   flip-to-flip with PresentMon (the Windows HUD equivalent).
7. Side screens need an indirect display driver (IddCx) for virtual
   desktops — that is the Windows CGVirtualDisplay. Park until 1-6 work.
8. SBS/stereo on Windows is gated on the vendor control transfer problem
   (PORTING.md "The hard part") — but the user's daily driver is mono
   60, and stereo caused them eye strain, so this is last, maybe never.

## Standing decisions (do not silently reopen)

- 120 Hz on Mac: closed, twice. Windows is the venue.
- SBS as a default: no — eye strain (vergence-accommodation). Occasional
  mode only.
- The faint grey scroll-lines: the panel's own, in every mode, case
  closed (RESEARCH.md).
- Temporal supersampling at 1:1: rejected by eye; mirror-mode re-test is
  the only open thread.
- HiDPI supersampling of the 2nd desktop: rejected by the user
  2026-08-15 (untested by eye; overkill + 2nd-desktop UX friction). The
  capture path keeps `maxWidth:` ready if ever revisited.
- Background themes: not worth it on birdbath optics — any non-black
  background is stray light in the eye.
