# HiDPI Supersampled Desktop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "1920×1200 2×" option to the 2nd-desktop source that renders the
desktop at Retina 2× (3840×2400 px backing) so Catmull-Rom minifies real 2×
detail onto the panel — and make sure the capture path does not silently throw
that detail away.

**Architecture:** Two small changes plus a live measurement. (1) `ScreenCapture.start`
grows a `maxWidth:` parameter (default 3008, the existing cap) so one caller can
raise it; a capture-size log line proves what was actually captured. (2)
`SpatialController.VirtualResolution` gains a `r1920x1200hi` case with
`hiDPI == true`, and the three main-capture call sites pass a computed
`captureMaxWidth` that uncaps only when the source is the hiDPI virtual desktop.
Then measure fps from the pacing log first, and only after that ask for the
user's eye verdict.

**Tech Stack:** Swift / SwiftPM app, ScreenCaptureKit, CGVirtualDisplay (private,
via CGVirtualDisplayShim). No test target exists in this repo — verification is
build + live run + reading `~/Library/Logs/RokidSpatial.log`.

## Global Constraints

- **Perceptual verdicts belong to the user's eyes; fps/functional claims must be measured** (house rule, ROADMAP.md).
- **Testbed is the 2nd-desktop source only.** Do not touch glasses-only mode in this experiment (ROADMAP item 1: "before touching glasses-only").
- **Batch app restarts** — every restart bounces the user's live session. Build everything, restart once for the measurement.
- Existing behavior for every current mode must be byte-identical: default `maxWidth` stays 3008, existing enum cases unchanged.
- Build with `./Scripts/make-app.sh` from the repo root. Test loop (only in the final task, with the user present): osascript quit → poll pgrep → `open ~/Applications/RokidSpatial.app --args --autostart` → read `~/Library/Logs/RokidSpatial.log` with `grep -v pacing` (and `grep pacing` for fps).
- If fps halves during measurement, run `pmset -g batt` FIRST (Low Power Mode clamps capture to 30).
- The user writes in Thai; reply in Thai. Code/comments/docs in English.

## Why the cap exists and why raising it here is safe

`capWidth = 3008` in `ScreenCapture.start` protects the *mirror* path from
paying 4K-capture bandwidth for detail the 50° FOV cannot resolve. The hiDPI
virtual desktop is different: its whole purpose is to hand the renderer a 2×
source to minify (same reason Retina screenshots downscale so well). Capturing
it clamped to 3008 would silently downscale 3840→3008→panel, erasing the point
of the experiment — this is the trap ROADMAP.md item 1 calls out. The risk that
remains is real: ~4× capture bandwidth through WindowServer (the same choke
point behind the LPM clamp). That is why Task 3 measures fps before any eye
verdict.

---

### Task 1: `ScreenCapture` — parametrize the capture-width cap and log the capture size

**Files:**
- Modify: `Sources/RokidSpatial/ScreenCapture.swift:45-102`

**Interfaces:**
- Consumes: nothing new.
- Produces: `func start(displayID: CGDirectDisplayID, frameRate: Int, excludingWindowNumber: Int? = nil, showsCursor: Bool = true, maxWidth: Int = 3008) async throws` — Task 2's call sites pass `maxWidth:`. Existing callers compile unchanged (defaulted parameter).

- [ ] **Step 1: Add the `maxWidth` parameter**

In `Sources/RokidSpatial/ScreenCapture.swift`, change the signature at line 45:

```swift
    func start(displayID: CGDirectDisplayID, frameRate: Int,
               excludingWindowNumber: Int? = nil,
               showsCursor: Bool = true,
               maxWidth: Int = 3008) async throws {
```

- [ ] **Step 2: Use it where the cap is applied, and log the result**

Replace lines 92-102 (the comment block, `capWidth`, `scale`, and the three
assignments) with:

```swift
        // Capture at the display's true pixel size so text stays crisp once
        // it is projected, but cap it — beyond this we are paying for detail
        // the 50° field of view cannot resolve anyway. The hiDPI virtual
        // desktop raises the cap: its 2× backing exists precisely to be
        // captured whole and minified by the renderer.
        let mode = CGDisplayCopyDisplayMode(displayID)
        let nativeWidth = mode?.pixelWidth ?? Int(CGDisplayPixelsWide(displayID))
        let nativeHeight = mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(displayID))
        let scale = nativeWidth > maxWidth ? Double(maxWidth) / Double(nativeWidth) : 1
        pixelWidth = Int(Double(nativeWidth) * scale)
        pixelHeight = Int(Double(nativeHeight) * scale)
        pointWidth = Int(CGDisplayPixelsWide(displayID))
        AppLog.append("capture: \(pixelWidth)×\(pixelHeight) px"
            + (scale < 1 ? " (capped from \(nativeWidth)×\(nativeHeight))" : "")
            + " @ \(frameRate) Hz from display \(displayID)")
```

(The log line is the measurement instrument for Task 3 — it proves whether the
3840 px surface actually reached the renderer or was silently clamped.)

- [ ] **Step 3: Build**

Run from `/Users/angkawornkrapanja/Documents/Rokid` (worktree or master — wherever this branch is checked out):

```bash
./Scripts/make-app.sh
```

Expected: build succeeds with no warnings about `start` call sites (the new
parameter is defaulted, so the three existing callers in
`SpatialController.swift` and the side-capture calls compile unchanged).

- [ ] **Step 4: Commit**

```bash
git add Sources/RokidSpatial/ScreenCapture.swift
git commit -m "ScreenCapture: parametrize the 3008 px width cap, log capture size"
```

---

### Task 2: `VirtualResolution` — add the 1920×1200 2× case and plumb the raised cap

**Files:**
- Modify: `Sources/RokidSpatial/SpatialController.swift:327-355` (enum), `:476` area (add computed property), `:636-641`, `:911-919`, `:1254-1260` (the three main-capture `capture.start` calls)
- Modify: `Sources/RokidSpatial/SettingsView.swift:182-187` (caption for the new option)

**Interfaces:**
- Consumes: `ScreenCapture.start(... maxWidth:)` from Task 1.
- Produces: `VirtualResolution.r1920x1200hi` (rawValue `"r1920x1200hi"`, `width == 1920`, `height == 1200`, `hiDPI == true`, `label == "1920 2×"`); `private var captureMaxWidth: Int` on `SpatialController`.

- [ ] **Step 1: Add the enum case**

In `Sources/RokidSpatial/SpatialController.swift`, the enum currently reads
(line 327):

```swift
    enum VirtualResolution: String, CaseIterable, Identifiable {
        case r1280x800
        case r1440x900
        case r1600x1000
        case r1920x1200
        /// SpaceWalker's Ultra-Wide: one 21:9 desktop instead of a wall of
        /// three. Best with the curved screen — a flat 21:9 at working
        /// distance leaves the edges visibly further away than the centre.
        case r2560x1080
```

Add one case between `r1920x1200` and the `r2560x1080` comment block:

```swift
        case r1920x1200
        /// The supersampling experiment (ROADMAP item 1): same 1920×1200
        /// points, but Retina-backed at 3840×2400 px. macOS renders text at
        /// 2× and Catmull-Rom minifies it onto the panel — real detail, not
        /// massaged detail. Costs ~4× capture bandwidth; the pacing log
        /// rules on whether 60 fps survives.
        case r1920x1200hi
        /// SpaceWalker's Ultra-Wide: one 21:9 desktop instead of a wall of
```

Then update the three computed properties in the same enum:

```swift
        var width: Int {
            switch self {
            case .r1280x800: return 1280
            case .r1440x900: return 1440
            case .r1600x1000: return 1600
            case .r1920x1200, .r1920x1200hi: return 1920
            case .r2560x1080: return 2560
            }
        }

        var height: Int { self == .r2560x1080 ? 1080 : width * 5 / 8 }
        var label: String {
            switch self {
            case .r2560x1080: return "21:9"
            case .r1920x1200hi: return "1920 2×"
            default: return "\(width)×\(height)"
            }
        }

        /// Retina backing is worth the pixels once the desktop is small enough
        /// that the virtual screen renders larger than its point size — or,
        /// for the supersampling experiment, at full size on purpose.
        var hiDPI: Bool {
            self == .r1280x800 || self == .r1440x900 || self == .r1920x1200hi
        }
```

(`height` needs no change: `1920 * 5 / 8 == 1200`. Persistence needs no
change: the `didSet` at line 34 stores the rawValue, and the restore at
line 493 round-trips any case.)

- [ ] **Step 2: Add `captureMaxWidth` and pass it at the three main-capture call sites**

Next to `captureRate` (line 476), add:

```swift
    /// The hiDPI virtual desktop must be captured at its full 2× backing —
    /// clamping it to 3008 would silently downscale 3840→3008 and erase the
    /// supersampling (the ROADMAP item 1 trap). Everything else keeps the
    /// FOV-derived cap.
    private var captureMaxWidth: Int {
        source == .virtualDesktop && virtualResolution.hiDPI
            ? max(3008, virtualResolution.width * 2)
            : 3008
    }
```

Then add `maxWidth: captureMaxWidth` to the three `capture.start` calls on the
main capture object (NOT the `sideCaptures` calls — side screens keep the
default):

Call site 1, `adaptCaptureToPowerState` (line 636):

```swift
            try? await capture.start(
                displayID: captureID,
                frameRate: captureRate,
                excludingWindowNumber: source == .glassesOnly ? window?.windowNumber : nil,
                showsCursor: source != .glassesOnly,
                maxWidth: captureMaxWidth
            )
```

Call site 2, the retry loop in `startCaptureAndRender` (line 911):

```swift
                try await capture.start(
                    displayID: captureID,
                    frameRate: captureRate,
                    excludingWindowNumber: source == .glassesOnly ? window?.windowNumber : nil,
                    // In glasses-only mode the renderer draws its own cursor;
                    // SCK's would be a duplicate whenever the system cursor
                    // transiently becomes visible again.
                    showsCursor: source != .glassesOnly,
                    maxWidth: captureMaxWidth
                )
```

Call site 3, the capture-death restart (line 1254 — note the `self.` prefix
in this closure):

```swift
                try await self.capture.start(
                    displayID: captureID,
                    frameRate: self.captureRate,
                    excludingWindowNumber: self.source == .glassesOnly
                        ? self.window?.windowNumber : nil,
                    showsCursor: self.source != .glassesOnly,
                    maxWidth: self.captureMaxWidth
                )
```

- [ ] **Step 3: Add the explainer caption in Settings**

In `Sources/RokidSpatial/SettingsView.swift`, after the existing 21:9 caption
block (lines 182-187), add a sibling caption — same pattern, so the option is
discoverable rather than mysterious (house rule: grey out / explain, don't
hide):

```swift
                if controller.virtualResolution == .r1920x1200hi {
                    Text("1920×1200 rendered at 2× (3840×2400) and downscaled onto the panel — sharper text, ~4× capture load. If it stutters, drop back to 1920×1200.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

- [ ] **Step 4: Build**

```bash
./Scripts/make-app.sh
```

Expected: clean build. The segmented picker gains a sixth segment ("1920 2×")
automatically via `ForEach(allCases)`.

- [ ] **Step 5: Commit**

```bash
git add Sources/RokidSpatial/SpatialController.swift Sources/RokidSpatial/SettingsView.swift
git commit -m "2nd desktop: 1920x1200 2x supersampling option (ROADMAP item 1)"
```

---

### Task 3: Live measurement (fps first), then the user's eye verdict

**This task needs the user present and bounces their running session — do it
once, batched, with their go-ahead.**

**Files:**
- Modify (after verdict): `ROADMAP.md:15-29` (item 1 status), `RESEARCH.md` (append verdict section)

**Interfaces:**
- Consumes: the "1920 2×" option and the `capture:` log line from Tasks 1-2.
- Produces: a measured fps number and a recorded user verdict; no code.

- [ ] **Step 1: Install the new build and restart the app (one restart)**

```bash
osascript -e 'quit app "RokidSpatial"'; while pgrep -x RokidSpatial >/dev/null; do sleep 0.5; done; open ~/Applications/RokidSpatial.app --args --autostart
```

(`make-app.sh` already installed to `~/Applications` in Task 2's build.)

- [ ] **Step 2: Ask the user to switch source to "2nd desktop" and pick "1920 2×", then Start**

The picker is disabled while running, so: Stop → source "2nd desktop" →
Desktop size "1920 2×" → Start. Ask them to move one window with small text
(a terminal or editor) onto the new desktop.

- [ ] **Step 3: Verify the capture is actually 2× (the trap check)**

```bash
tail -50 ~/Library/Logs/RokidSpatial.log | grep "capture:"
```

Expected: `capture: 3840×2400 px @ 60 Hz from display <id>`. If it says
`3008×…` or `1920×…`, the cap or the hiDPI creation did not take — STOP,
diagnose before any perceptual question (`grep -v pacing` the log; check the
`settings.hiDPI` path in VirtualDisplay).

- [ ] **Step 4: Measure fps for at least 30 s under normal use**

```bash
tail -f ~/Library/Logs/RokidSpatial.log | grep pacing
```

Expected: `pacing: 60 fps avg, 0 slow frames in 10 s` lines, three in a row,
while the user scrolls a page on the virtual desktop. If fps is halved or slow
frames pile up: run `pmset -g batt` FIRST (Low Power Mode explains a clean
30). If it is genuinely capture-bandwidth-bound (fps sags on AC power), the
experiment fails the measurement gate — report the number, do not ask for an
eye verdict on a stuttering image.

- [ ] **Step 5: The eye verdict (user only) — A/B against plain 1920×1200**

Ask the user (in Thai) to look at the same small-text window in "1920 2×",
then Stop → switch to "1920×1200" → Start (second and final restart pair),
same window. The question is only: **is text visibly sharper at 2×, and is
motion still smooth?** Sharpness and comfort are separate axes — if they
report anything about eye strain, record it separately; never trade one axis
for the other.

- [ ] **Step 6: Record the verdict**

Whatever the outcome, append a dated section to `RESEARCH.md` (pattern:
existing "The image-quality pipeline, and the temporal verdict" section) with:
the measured capture size, the pacing numbers on AC, and the user's words.
Update ROADMAP.md item 1: either "SHIPPED — default for 2nd desktop stays
user's choice" or "REJECTED — <measured/eye reason>", so the list stays a
truthful ranking. If rejected on bandwidth, note whether a 1600×1000 2×
(3200 px, only just over the cap) is worth a follow-up test before closing.

- [ ] **Step 7: Commit the docs**

```bash
git add ROADMAP.md RESEARCH.md
git commit -m "HiDPI supersampling verdict: <outcome>"
```

---

## Self-review notes

- **Spec coverage:** ROADMAP item 1 names three requirements — hiDPI creation
  (already plumbed, Task 2 turns it on), the capWidth trap (Task 1 + Task 3
  step 3 verifies), measure-fps-first (Task 3 steps 3-4 gate step 5).
  Cheapest-testbed constraint (2nd desktop, not glasses-only) is held by
  `captureMaxWidth` guarding on `source == .virtualDesktop`.
- **Type consistency:** `r1920x1200hi` rawValue/case name matches across enum,
  SettingsView caption, and nothing else references it. `maxWidth: Int = 3008`
  default keeps side captures and all other modes byte-identical.
- **No test target exists**; the verification instrument is the new `capture:`
  log line plus the existing pacing log — consistent with the repo's
  measurement-first practice.
