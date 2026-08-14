# Ultra-Wide 21:9 in Glasses-only + retire 2nd desktop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Glasses-only gains an "Ultra-Wide 21:9" toggle (a 2560×1080 working
virtual desktop, SBS-60-style arrangement) and the `.virtualDesktop` capture
source plus the `VirtualResolution` enum are deleted; sources become exactly
Mirror Mac and Glasses only.

**Architecture:** Spec at
`docs/superpowers/specs/2026-08-15-ultrawide-glasses-only-design.md`.
Reconnaissance with every touch point and verified anchors at
`/Users/angkawornkrapanja/Documents/Rokid/.git/worktrees/infallible-jang-f64a62/sdd/recon-ultrawide.md`
— **each implementer reads it before editing; line numbers there may drift a
few lines as tasks land, so match on the quoted excerpts.** The chosen
arrangement is MIRRORED, SBS-60 STYLE: working display 2560×1080@60 is the
wall main at origin, glasses display parked above (shows only the overlay),
built-in mirror-slaved to the working display, watchdog `allowedMaster` = the
working display, `restorePanelOnly(remirror: true)` on stop.

**Tech Stack:** Swift/SwiftPM, ScreenCaptureKit, CGVirtualDisplay. No test
target — verification is `./Scripts/make-app.sh` clean build per task, live
run in Task 4.

## Global Constraints

- Work in the worktree `/Users/angkawornkrapanja/Documents/Rokid/.claude/worktrees/infallible-jang-f64a62`, branch `claude/infallible-jang-f64a62`. Never touch master.
- Perceptual verdicts belong to the user's eyes; functional claims must be measured (pacing log, `capture:` log line).
- Batch app restarts — Tasks 1-3 must not quit/relaunch the running app; only Task 4 restarts, once, with the user present.
- Mirror Mac source behavior stays byte-identical. Renderer/VirtualScreen/ScreenCapture need zero changes (recon §3; 2560 < the 3008 capture cap).
- Persisted `source == "virtualDesktop"` must degrade silently to the enum default (recon §5 confirms it does by construction — verify, don't add migration code).
- New persisted key: `ultraWide` (bool, default false).
- UI rule: grey out, don't hide (the Layout row at SettingsView.swift:207-224 is the pattern). No new segmented-picker segments — the pickers are at capacity (SettingsView.swift:5-13 documents the overflow regression).
- Every commit message ends with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Build with `./Scripts/make-app.sh`; expect only the pre-existing Sendable/RokidIMU warnings.

---

### Task 1: State + full mechanical removal of the 2nd-desktop source

**Files:**
- Modify: `Sources/RokidSpatial/SpatialController.swift` (sites in recon §1 + §5)
- Modify: `Sources/RokidSpatial/SettingsView.swift` (recon §1)
- Modify: `Sources/RokidSpatial/AppDelegate.swift:55` (comment only)

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Tasks 2-3): `@Published var ultraWide: Bool` (persisted key `"ultraWide"`); `var ultraWideActive: Bool { source == .glassesOnly && sbsMode == .off && ultraWide }`; `var workingDesktopActive: Bool { stereoActive || ultraWideActive }`. `CaptureSource` has exactly `mirror` and `glassesOnly`. `VirtualResolution` and `virtualIsMain` no longer exist.

- [ ] **Step 1: Read the recon file** (path in the header). Your sites: recon §1 (all), §5 (persistence lines).

- [ ] **Step 2: Add the new state**

Replace the deleted `virtualResolution` (line 34) and `virtualIsMain` (36-38) properties with:

```swift
    /// Ultra-Wide 21:9: glasses-only works on one panoramic 2560×1080
    /// desktop instead of the panel-native one. Replaces the side screens
    /// (SpaceWalker's own concept — one wide desktop, not a wall of three).
    @Published var ultraWide = false { didSet { persist(ultraWide, "ultraWide") } }
```

Next to `standaloneActive` (line ~251) add:

```swift
    /// Ultra-wide runs the SBS-60 arrangement shape without the stereo
    /// panel: a working virtual desktop is the wall main, the built-in
    /// mirrors it, and the glasses display shows only the overlay.
    var ultraWideActive: Bool { source == .glassesOnly && sbsMode == .off && ultraWide }
    /// True whenever the desktop being captured is a virtual display we
    /// created rather than a physical one.
    var workingDesktopActive: Bool { stereoActive || ultraWideActive }
```

In the restore block (recon §5), replace the two deleted lines (493-496) with:

```swift
        if d.object(forKey: "ultraWide") != nil { ultraWide = d.bool(forKey: "ultraWide") }
```

- [ ] **Step 3: Delete the enum cases and rewrite every switch (recon §1)**

- `CaptureSource`: delete `case virtualDesktop`, its `label` arm (`"2nd desktop"`), its `detail` arm; reword the enclosing doc comment (289-295) so it no longer sells the separate desktop.
- Delete the whole `VirtualResolution` enum (325-352).
- `adaptCaptureToPowerState` (~628): delete the `.virtualDesktop` case; the glasses-only arm becomes
  `captureID = workingDesktopActive ? virtualDisplay.displayID : displays.glassesDisplayID`
- `handleCaptureDeath` (~1247): same two edits (`self.` prefixes).
- `startCaptureAndRender` (~788-822): delete the `.virtualDesktop` case; widen the working-desktop guard from `if stereoActive` to `if workingDesktopActive` (its body — the `guard let id = virtualDisplay.displayID else { abort(...) }` — is unchanged).
- Creation gate (~728-753) becomes:

```swift
        if workingDesktopActive {
            setStatus(stereoActive ? "Creating the \(frameRate) Hz working desktop…"
                                   : "Creating the Ultra-Wide desktop…")
            do {
                if stereoActive {
                    // The size matches the per-eye panel raster exactly, and
                    // the rate matches the panel: a slower virtual display in
                    // the set drags the whole composition down (measured
                    // 2026-08-12).
                    let size = sbsMode.desktopSize
                    try virtualDisplay.create(width: size.width, height: size.height,
                                              hiDPI: false,
                                              refreshRate: Double(frameRate))
                } else {
                    // SpaceWalker's Ultra-Wide: one 21:9 desktop instead of
                    // a wall of three. Best with the curved screen — a flat
                    // 21:9 at working distance leaves the edges visibly
                    // further away than the centre.
                    try virtualDisplay.create(width: 2560, height: 1080,
                                              hiDPI: false, refreshRate: 60)
                }
            } catch {
                setStatus("\(error)", isError: true)
                isStarting = false
                return
            }
        }
```

(Keep the load-bearing create-before-reconfiguration comment at 721-727.)
- `applyArrangement` (~1180-1191): with `virtualID` always nil, reduce it to arranging `main = deskID, rest = [glassesID]` — keep the existing `displays.arrange(main:then:)` call shape and any guards the current body has.
- Side screens must not be created under ultra-wide: find the side-display creation in `start()` (near line 851, `identity: UInt32(2 + index)`) and gate the loop on `!ultraWideActive` in addition to its existing conditions.

- [ ] **Step 4: SettingsView**

- Delete the whole `if controller.source == .virtualDesktop` block (171-191).
- In the glasses-only section, ABOVE the Side screens row (~193), add the toggle + caption:

```swift
                Toggle("Ultra-Wide 21:9", isOn: $controller.ultraWide)
                    .font(.caption)
                    .disabled(controller.isRunning || controller.sbsMode != .off)
                if controller.ultraWide {
                    Text("One panoramic 2560×1080 desktop — replaces the side screens. Turn on Curved screen so the edges stay the same distance as the centre.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

- Side screens picker (~203): `.disabled(controller.isRunning)` becomes `.disabled(controller.isRunning || controller.ultraWide)`. Below the picker (greyed-not-hidden explanation, only when it is the reason), add:

```swift
                if controller.ultraWide {
                    Text("Side screens are replaced by the Ultra-Wide desktop — turn 21:9 off to use them.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

- [ ] **Step 5: AppDelegate:55** — comment now reads `// capture source by raw value (mirror, glassesOnly).`

- [ ] **Step 6: Build**

Run: `./Scripts/make-app.sh` — expect clean (only pre-existing warnings). The compiler is your completeness check: any missed `.virtualDesktop`/`virtualResolution`/`virtualIsMain` reference fails the build.

- [ ] **Step 7: Commit**

```bash
git add Sources/RokidSpatial/SpatialController.swift Sources/RokidSpatial/SettingsView.swift Sources/RokidSpatial/AppDelegate.swift
git commit -m "2nd desktop retired; Ultra-Wide 21:9 becomes a glasses-only toggle (state+UI)"
```

Note: after this task the toggle exists but a live ultra-wide session is NOT yet correctly arranged (Tasks 2-3). That is fine — nothing merges until Task 4 verifies.

---

### Task 2: Start-path arrangement for ultra-wide (SBS-60 shape)

**Files:**
- Modify: `Sources/RokidSpatial/SpatialController.swift` (prep branch ~755-780; wall-layout block ~977-1009; `standaloneParked` ~1168-1173; `mergeBuiltin`'s definition — grep it; the four `restorePanelOnly(remirror:)` calls at ~1209, ~1302, ~1328, ~1881)
- Modify: `Sources/RokidSpatial/DisplayManager.swift:329-331` (`prepareStandalone` resolution pick)
- Modify: `Sources/RokidSpatial/AppDelegate.swift` (~61-72, debug flag)

**Interfaces:**
- Consumes: `ultraWideActive` / `workingDesktopActive` from Task 1.
- Produces: a live ultra-wide session arranges as: working display main at origin, glasses parked, built-in mirrored onto working; every exit path re-mirrors the panel. `--ultrawide` CLI flag for Task 4.

- [ ] **Step 1: Read the recon file**, §2 and §6 header rows, plus the current code at each site.

- [ ] **Step 2: Panel prep** — in `start()`'s prep dispatch (~763-773), route ultra-wide to the standalone preparer:

```swift
                if standaloneActive || ultraWideActive {
                    try displays.prepareStandalone(mode: displayMode)
                } else if source == .glassesOnly {
                    try displays.prepareGlassesOnly(mode: displayMode)
                } else {
                    // Let macOS enumerate the new display before rearranging.
                    Thread.sleep(forTimeInterval: 2.0)
                    try displays.prepare(mode: displayMode)
                }
```

(`displayMode` is already `.sameOnBoth` for ultra-wide since `standaloneActive` is false — verify at ~755. The closure's capture list must gain whatever it needs; it currently captures `[displays, source, standaloneActive]`.)

In `DisplayManager.prepareStandalone` (329-331), give `.sameOnBoth` a real desktop instead of the SBS sliver:

```swift
        setDesktopResolution(glassesID, width: 1920,
                             height: mode == .highRefreshRate || mode == .sameOnBoth ? 1080
                                   : mode == .highRefreshRateSBS ? 600 : 540)
```

- [ ] **Step 3: Wall layout** — the block at ~977-1009 (`standaloneParked` / `fixWallLayout` / `mergeBuiltin`) runs only for the standalone modes today; widen its gate to include `ultraWideActive` (read the surrounding code to find the exact gate). Then:
- `standaloneParked` (~1168-1173): the desk is excluded whenever the built-in mirrors the working display:

```swift
        [displays.glassesDisplayID,
         sbsMode == .sbs60 || ultraWideActive ? nil : displays.deskDisplayID]
```

(match the function's actual body/optionals — the recon quotes its shape).
- `mergeBuiltin`: grep its definition (it decides `mirrorBuiltinOntoWorking`; today true only for SBS-60) and OR in `ultraWideActive`.

- [ ] **Step 4: Exit paths** — all four `displays.restorePanelOnly(remirror: standaloneActive)` calls become `remirror: standaloneActive || ultraWideActive` (~1209, ~1302, ~1328, ~1881; some are inside closures with `self.`).

- [ ] **Step 5: Debug flag** — in AppDelegate next to the `--sbs=` handling (~61-72), following its exact style:

```swift
        if CommandLine.arguments.contains("--ultrawide") {
            controller.ultraWide = true
        }
```

- [ ] **Step 6: Build** — `./Scripts/make-app.sh`, clean.

- [ ] **Step 7: Commit**

```bash
git add Sources/RokidSpatial/SpatialController.swift Sources/RokidSpatial/DisplayManager.swift Sources/RokidSpatial/AppDelegate.swift
git commit -m "Ultra-Wide start path: SBS-60 arrangement shape at 60 Hz mono"
```

---

### Task 3: Watchdog and recovery learn ultra-wide

**Files:**
- Modify: `Sources/RokidSpatial/SpatialController.swift` — `healthCheck` (~1721-1866), `hiddenDisplayIDs` (~1159-1166), `strandedApps` (~1683-1692)

**Interfaces:**
- Consumes: `ultraWideActive` / `workingDesktopActive`.
- Produces: the 1 Hz watchdog defends the ultra-wide arrangement instead of fighting it.

- [ ] **Step 1: Read the recon file §6** — it lists each site with the hazard. Apply, matching on the quoted excerpts:

1. `allowedMaster` (~1739): `sbsMode == .sbs60 || ultraWideActive ? virtualDisplay.displayID : nil`
2. Mirror check (~1740-41): both `standaloneActive` mentions become `standaloneActive || ultraWideActive` (outer condition AND the ternary selector), so ultra-wide takes the `unexpectedMirror(allowedMaster:)` branch — under ultra-wide, built-in-mirrors-working is the DESIRED state and mirror-onto-glasses is not.
3. Recovery (~1746-1758): the `if !standaloneActive { applyArrangement() }` at ~1756 becomes `if !standaloneActive, !ultraWideActive { applyArrangement() }`.
4. Plain-glasses-only re-mirror (~1771-1778): add `, !ultraWideActive` to the condition — THIS IS THE BIGGEST HAZARD; without it the watchdog re-mirrors the built-in onto the glasses every second, fighting the session.
5. Wall check (~1794-1821): `let mainID = stereoActive || ultraWideActive ? virtualDisplay.displayID : glassesID`; the parked list `standaloneActive ? standaloneParked(...) : []` becomes `standaloneActive || ultraWideActive ? standaloneParked(...) : []`.
6. Hidden-desktop window rescue (~1822-1846): gate `standaloneActive` widens to `standaloneActive || ultraWideActive` (the glasses display is parked under ultra-wide; windows can strand on it).
7. `hiddenDisplayIDs` (~1159-1166): `guard standaloneActive` → `guard workingDesktopActive`; its `mainID` ternary `stereoActive ? ...` → `stereoActive || ultraWideActive ? ...`.
8. `strandedApps` (~1683-1692): same two-part edit as 7.

- [ ] **Step 2: Self-check** — grep the file for `standaloneActive` and `stereoActive` and, for every remaining hit not listed above, write one line in your report saying why ultra-wide is correctly handled there (most are stereo-/SBS-specific and correct as-is). This is the completeness net for the "three copies of every decision" trap.

- [ ] **Step 3: Build** — `./Scripts/make-app.sh`, clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/RokidSpatial/SpatialController.swift
git commit -m "Watchdog defends the Ultra-Wide arrangement instead of fighting it"
```

---

### Task 4: Live verification (user present), docs, merge

**This task bounces the user's session once and needs their eyes. Controller coordinates; do not start it unbidden.**

- [ ] **Step 1: Restart into the new build** (single restart): quit via osascript, poll pgrep, `open ~/Applications/RokidSpatial.app --args --autostart`.
- [ ] **Step 2: User flips "Ultra-Wide 21:9" on** (Stop → toggle → Start), moves a small-text window onto the panoramic desktop.
- [ ] **Step 3: Measure first**: log must show `capture: 2560×1080 px @ 60 Hz from display <virtual id>`; pacing holds ~60 fps with few slow frames for 3+ windows; watchdog log must be quiet (no once-a-second mirror fights — grep the log for repeated `mirror`/`layout` lines). If the watchdog is fighting, STOP and fix before any eye question.
- [ ] **Step 4: Eye verdict (user only)**: is the panoramic desktop worth it — sharpness (2560 points across a wider virtual screen), comfort, window workflow. Toggle off/on comparison as they like. Also confirm Stop returns the machine to a plain mirror (every exit path must leave the machine escapable).
- [ ] **Step 5: Docs**: RESEARCH.md dated section (what shipped, measured numbers, verdict verbatim); ROADMAP.md — mark the 2nd-desktop retirement as done (its Standing-decision entry updates from "rejected supersampling" context if needed), re-scope item 2 (MetalFX — its main use case, small 2nd-desktop sizes, is gone; keep only if ultra-wide magnification wants it) and item 4 (temporal mirror-mode re-test unaffected); note the new toggle in README.md if the features list there mentions 2nd desktop / 21:9 (check it).
- [ ] **Step 6: Commit docs, then merge**: `git -C /Users/angkawornkrapanja/Documents/Rokid merge --ff-only claude/infallible-jang-f64a62 && git -C /Users/angkawornkrapanja/Documents/Rokid push origin master` — only after Steps 3-4 pass.

---

## Self-review notes

- Spec coverage: toggle+grey-out (T1 S4), working-desktop mechanism (T1 S3 creation + T2 arrangement), three capture-target copies (T1 S3 — all three named), watchdog (T3, all eight recon sites), removal + safe persistence fallback (T1), mirror untouched (no mirror-path file is edited beyond shared switches whose `.mirror` arms stay), verification order measure-then-eye (T4).
- Type consistency: `ultraWide` / `ultraWideActive` / `workingDesktopActive` named identically across tasks; `CaptureSource` two-case shape produced in T1 is what T2/T3 code assumes.
- The compiler enforces removal completeness (exhaustive switches); T3 S2's grep sweep covers the boolean-gate sites the compiler cannot check.
