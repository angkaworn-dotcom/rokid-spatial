# Ultra-Wide 21:9 in Glasses-only; retire the 2nd-desktop source — design

Approved by the user 2026-08-15 (Thai session). Context: the user judged the
2nd-desktop source not worth its friction (arrange-windows-by-hand, and its
Desktop-size picker was the site of today's Settings-overflow regression). The
only thing in it worth keeping is Ultra-Wide 21:9, which moves into
Glasses-only. Sources become exactly two: **Mirror Mac** and **Glasses only**.

## Feature: Ultra-Wide 21:9 in Glasses-only

**Mechanism — the working-desktop pattern** (the same one the stereo/SBS
standalone variants already use): when the toggle is on, Glasses-only creates
a 2560×1080 @ 60 Hz virtual display as the working desktop, makes it the main
display (menu bar and new windows land there), captures *it* instead of the
glasses display, and renders onto the panel with the same virtual-screen
geometry 21:9 had under the 2nd-desktop source. The capture hook is the
existing one-liner: `captureID = stereoActive ? virtualDisplay.displayID :
displays.glassesDisplayID` grows an ultra-wide condition; the creation gate
`if source == .virtualDesktop || stereoActive` likewise. 2560 px is under the
3008 capture cap — no capture changes needed.

Rejected alternative: asking the glasses panel for a scaled 2560×1080 desktop
mode directly — the panel does not offer it, and capturing 2560 points into
1920 native pixels loses detail at the capture stage.

**UI:** a "Ultra-Wide 21:9" toggle in the Screen tab, Glasses-only section
(the segmented pickers are at capacity — today's lesson). When on, the Side
screens picker is greyed out (not hidden) with a one-line caption: ultra-wide
replaces the side screens (SpaceWalker's own concept; user chose this over
combining them). The existing 21:9 advice to enable Curved screen carries
over as the toggle's caption.

**Interactions:** mutually exclusive with side screens (greyed, remembered).
Mono only — no interaction with SBS/stereo modes, which have their own
working desktops. Persisted as a new bool default (`ultraWide`).

## Removal: the 2nd-desktop source

- `CaptureSource.virtualDesktop` deleted; the source picker shows two
  segments: Mirror Mac, Glasses only.
- `VirtualResolution` enum, the Desktop-size picker, its captions, and the
  "Work in the glasses" toggle (`virtualIsMain`) deleted — 21:9 is a toggle
  now, not a resolution.
- Migration: a persisted `source == "virtualDesktop"` no longer matches any
  rawValue, so the restore path keeps the default source — verified safe
  today (the same fallback absorbed the withdrawn `r1920x1200hi`). No
  explicit migration code.
- Mirror Mac is untouched.

## Risks & verification

The one risky moment is start-time display arrangement (the re-mirror war);
it is entirely reused, battle-tested code. Verification order, per house
rule: build → restart → toggle on → log shows `capture: 2560×1080 px @ 60 Hz`
→ pacing holds 60/0 → only then the user's eye verdict on whether 21:9 in
Glasses-only earns its keep. Verdict lands in RESEARCH.md; ROADMAP.md updates
(2nd desktop retired; MetalFX item 2 loses its main use case and is
re-scoped or closed).
