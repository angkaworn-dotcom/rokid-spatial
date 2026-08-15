# SBS/stereo/standalone removal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** RokidSpatial supports exactly two sources — Mirror Mac and Glasses
only — both mono 2D 60 Hz, panel mode 0 only. SBS 60/90, 120 Hz, stereo
rendering, IPD, standalone wall machinery, and their dead dependents are
removed. Plain glasses-only side screens (0/1/2 + Wide/Portrait/Stacked)
survive intact.

**Why (record in docs):** the user's 2026-08-12 verdict (SBS = eye strain,
vergence-accommodation; never used since) + 2026-08-15 decision ("ตัด SBS
ออกไปเลย") + market confirmation mined from the VITURE SpaceWalker binary the
same night: no user-facing stereo on Mac at all — its firmware enum has SBS
modes but no code path reaches them, and it actively forces glasses back to
2D. (Also correct the record: SpaceWalker is VITURE's app, not Rokid's.)

**Architecture:** guided removal, compiler as the completeness net. The
authoritative site-by-site map with (delete)/(rewrite)/(keep) verdicts is the
recon embedded in the implementer's dispatch. CRITICAL KEEPs: the wall-layout
watchdog with `mainID = glassesID, parked = []`; `reassertGlassesOnlyMirror`;
side-display create/capture/layout (portrait/stacked guards lose their
`!standaloneActive` term, not their logic); `RokidKit/DisplayMode.swift`,
`Tools/rokid-display-mode.c`, `Scripts/rescue.sh`, `main.swift --panel-mode`
probe, `ScreenCapture.swift` in full.

## Global Constraints

- Worktree `/Users/angkawornkrapanja/Documents/Rokid/.claude/worktrees/infallible-jang-f64a62`, branch `claude/infallible-jang-f64a62`; never touch master directly.
- App not running; do not launch it during implementation (controller does the live test).
- Build gate: `./Scripts/make-app.sh` clean (pre-existing Sendable warnings only).
- Grep gates after the code task: `grep -riE "sbsMode|SBSMode|stereoActive|standaloneActive|sbs90|hz120|\bipd\b" Sources/` → only allowed hits are `main.swift` panel-mode probe comments (if any) and historical strings deliberately kept; `grep -r "SpaceWatch\|WindowRescue\|bounceCaptureForSpaceChange\|standaloneParked\|prepareStandalone\|mirrorBuiltinOntoWorking\|unexpectedMirror\|rehomeDockIfHidden" Sources/` → empty.
- Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

### Task 1: The removal (single atomic task — the sites are interdependent)

Files: SpatialController.swift, SettingsView.swift, AppDelegate.swift,
DisplayManager.swift, Renderer.swift, VirtualScreen.swift (RokidKit),
main.swift (comment), DELETE SpaceWatch.swift and WindowRescue.swift.

- [ ] Apply the recon map (in dispatch) site by site; comment sweeps included
- [ ] Build clean; run the grep gates
- [ ] Commit: "SBS, stereo, 120 Hz removed: the app is what the user uses"

### Task 2: Live smoke test (controller-run), docs, merge

- [ ] Launch `--autostart` (glasses-only 60): log shows `capture: 1920×1080 px @ 60 Hz`, `Running — 1920×1080 @ 60 Hz`, 3 healthy pacing windows; Settings opens; quit → mirror + panel restored (winwhere probe)
- [ ] Repeat once with side screens L+R enabled via defaults (`sideScreens` key) to prove the wall survives — sides enumerate, wall check quiet
- [ ] Docs: ROADMAP (Windows-port checklist items 7-8 re-scoped: side screens stay, SBS gone; Standing decisions entry: SBS removed 2026-08-15 — eye-strain verdict + VITURE market confirmation; sweep stale SBS references); RESEARCH.md dated closing entry (verdict verbatim, VITURE correction, what was removed/kept); README feature list sweep
- [ ] Commit docs: "SBS post-mortem: the market agreed with the user's eyes"
- [ ] `git -C /Users/angkawornkrapanja/Documents/Rokid merge --ff-only claude/infallible-jang-f64a62 && git -C /Users/angkawornkrapanja/Documents/Rokid push origin master`
