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

## Faint grey double lines during head movement (2026-08-12)

Symptom: very faint grey lines that appear on any head movement, all modes.
Root cause, **confirmed by eye**: frame-duplication ghosting. The window
server had stopped flipping the glasses display at 120 Hz and settled at
the mirror set's 60 Hz member rate — `sample` showed the render thread 73%
blocked in `nextDrawable` — so every rendered frame was scanned out twice,
and pursuit eye motion splits high-contrast edges into a faint double image.
At 60 Hz (panel mode 0, render and refresh 1:1) the lines vanish entirely.

What did NOT fix the 60 Hz stick (all tested live):

- **RGSS anti-moiré resample** (Ben Golus's 4-tap rotated grid; also what
  godot-xr-tools #459 recommends): shipped as a toggle, correct fix for
  resampling moiré, but this artifact wasn't moiré — lines persisted.
- **Scanout kick** (re-ordering the overlay window when fps sits below 100
  for 10 s): fires, never recovers the flip rate.
- **Native desktop size** (1920×1200 instead of scaled 1344×840): no change.
- **Disabling both side screens**: no change.
- Pausing the 60 fps video, closing/restarting the app, Stop/Start: no
  change. The stick survives everything short of (untested) a reboot or
  glasses re-plug.

Timeline note: 120 Hz flips (120 fps, 0 slow) worked for half an hour
(03:38–04:16), then degraded and never returned. Trigger unknown.

Resolution: the user chose 60 Hz as the daily driver — most content is
60 fps anyway, and with flips stuck at 60 the 120 Hz mode buys nothing but
the ghosting. 60 Hz runs 1:1 with 0 slow frames. If 120 Hz flips are ever
worth chasing again: try a Mac reboot / glasses re-plug first to see if the
window-server state clears, and check whether the golden window correlates
with *nothing else on the desktop having ever animated* since session start.

### Update, same day: real 120 Hz recovered — standalone + matched-rate sides

The 60 Hz stick was two separate drags, isolated live:

1. **The mirror set.** macOS harmonizes a mirror set's flip rate down to
   its 60 Hz member (BetterDisplay #121/#4280 document this; the half-hour
   of 120-while-mirrored earlier rode on direct-scanout luck that never
   returned). Fix: `standalone120` — glasses-only without the mirror,
   glasses main at the origin, built-in parked below, dark. The re-mirror
   war machinery (enforceUnmirrored + watchdog re-assert) guards it.
2. **60 Hz virtual side displays.** Even unmirrored, the two side screens
   dragged flips to a fluctuating 60–92. They were created at
   CGVirtualDisplay's default 60 Hz; creating them at the panel's rate
   (120) fixed it — all three screens now pace at ~118–120.

Measured end state: standalone + L+R sides at 120 Hz → 118–120 fps avg,
0–16 slow per 10 s. Mirrored mode remains the default (trap-free); the
experiment toggle is "No mirror (120 Hz experiment)" in More.
Untested interaction: scaled desktop sizes (e.g. 1344×840) under
standalone — the compositor scaling may or may not drag the rate again.

### Final call on 120 Hz (Mac): parked — it's a timing-negotiation problem

User-sourced findings (2026-08-12):

- Rokid Max 1 hardware genuinely does 120 Hz: verified by users on PC,
  and custom timing reaches 144 Hz at 1920×1080.
- A Windows report of 1920×1200@120 negotiating but showing a black
  screen was fixed with **custom timing** — so the 120 Hz faint-line
  artifact here is most likely DP mode/timing negotiation, not the panel.
- Station 2 is not a fix: Rokid specifies Max + Station 2 runs the whole
  system at 90 Hz (Max reaches 120 only on other hosts).
- Firmware cannot be updated without a Station 2 (Rokid AR app failed to
  see the glasses from iPad and Samsung phone alike); current fw **0.40**
  (the "512" once recorded here was bcdDevice, the static USB device
  release number — not a firmware version. The real one is an ASCII
  string behind vendor query selector 0x00; see PROTOCOL.md).

Decision: **Mac version stays 60 Hz** (1:1, clean image, daily driver).
120 Hz effort moves to the Windows port, where custom timing tools (CRU)
exist to fix the negotiation. macOS EDID overrides could in principle do
custom timing too — parked unless someone feels brave.

### SBS-90 built (2026-08-12, same day) — and what the eye said

Mode 4 (3840×1200 @ 90 Hz SBS) first cleared a bare-desktop eye test via
the new `--panel-mode=4 --hold=60` probe ("ไม่มีเส้นนะ ชัดดี"), so the
Station-2-style mode was built as the opt-in **"SBS 90 Hz (stereo)"**
toggle under glasses-only: a 1920×1200 @ 90 Hz virtual display is the
working desktop (mode 4's own desktop is a 1920×600-point 16:5 sliver),
the stereo render path draws per-eye viewports with the live IPD slider
(range widened to 0–120 mm on request — it is a depth/comfort knob, not
anatomy), and the whole set runs **standalone** — any mirror member
harmonizes flips to 60. Sides L+R at 1920×1200@90 work.

Measured: **90 fps avg, 0 slow** with the full wall (main + L+R sides,
five displays online) once the machine is quiet; ~20 s of settling churn
after start; heavy foreground load (a chat app streaming text) drags it
to ~80 with hundreds of slow frames. 60 fps floor held except transient
startup dips.

The eye verdict with real content, refining the bare-desktop test:
**faint grey lines exist at 90 too** — far weaker than the 120 Hz mode
("ต้องสังเกตถึงเห็น"), *much* more visible on white backgrounds, and
present even at a measured 90-flips-per-second 1:1 — so this is NOT
frame duplication; the timing artifact simply scales with refresh rate
(60 clean → 90 faint → 120 obvious). Stereo depth judged clearly better
("มิติภาพดีกว่า"), sharpness good, motion smooth at 1:1. Daily-driver
choice (clean 60 vs deep-but-faintly-lined 90) stays with the user.

**Case closed on the faint lines (same day, later):** the sensitive test
is a white window with text, scrolled, watched through the glasses. With
it, the faint lines appear in *every* condition: SBS-90, SBS-60, plain
2D 60 in-session — and, decisively, **with the app closed entirely**
(raw mirrored desktop, direct scanout, no capture chain). Eliminated one
by one, live: stereo disparity (IPD 0 — no change), renderer moiré
(RGSS toggle — no change), frame duplication (measured 90/0 1:1 — still
there), the capture chain (app closed — still there). The faint
scroll-ghost is **inherent to the panel/optics** (sample-and-hold
pursuit ghosting on high-contrast scrolling content) and has been there
since day one; nobody had looked the sensitive way before. It is not
fixable host-side on any OS. The *obvious* 120 Hz lines remain a real,
separate artifact (frame duplication, proven earlier). Consequence: the
mode choice is purely depth (SBS) vs simplicity and 60 vs 90 smoothness
— the faint lines are a constant everywhere.

Traps found live during the build, all now defended:

1. **The re-applied mirror is not always onto the glasses.** Creating
   the side displays made macOS mirror the built-in onto the *left side*
   virtual display; a glasses-focused mirror check missed it, a mirrored
   display cannot be repositioned, and the wall watchdog looped once a
   second forever. SBS's watchdog now faults on *any* mirrored display
   (`DisplayManager.anyDisplayMirrored`), and the initial arrangement
   clears mirrors first.
2. **The settings window strands on the dark parked built-in.** The user
   could see nothing clickable and had to ⌃⌥Esc. The window now
   relocates to the origin display when an SBS session starts and on
   every menu-bar reopen.

## The direct-scanout instrument, and what it read (2026-08-12, third session)

The 60-flip stick finally has a measuring stick: the Metal Performance
HUD, enabled programmatically on the overlay's CAMetalLayer
(`developerHUDProperties` — must be set *after* the view joins the
window, or MTKView's backing layer does not exist yet and the cast
fails silently; cost half an hour). Now a persisted settings toggle
("Performance HUD"), flips live.

What it read, in mode 3 (1920×1080 @ 120, per user preference — the
panel offers a real 1:1 1920×1080@120):

- Stuck phase: **`Composited`** (orange), FPS 63, frame interval
  15.8 ms — on a 120 Hz panel. GPU time 0.47 ms: the app is nowhere
  near the bottleneck. `sample` agrees: ~78 % of render-thread time
  blocked in `nextDrawable` — WindowServer holding our drawables.
- **A glasses USB re-plug clears the stick** (first time tested):
  ~110 fps for ~80 s immediately after, then sagged back to ~63.
- But it is NOT a hard stick this session: with the machine idle it
  climbed back on its own — 62 → 100 → sustained 110-149 — with zero
  app-side events in the log. WindowServer oscillates between a fast
  path (direct-ish, ~110+) and the composited 60-ish path on its own
  schedule.
- Circumstantial: while fast, screencapture of the display did NOT
  show the HUD box (it did while composited) — consistent with the
  HUD riding a direct-scanout present that bypasses the capture
  composite. Not yet confirmed by an eye-read of Direct.

Traps fixed along the way, both "Settings won't open" reports in the
standalone modes:

1. The fixed 1/5/10/20 s relocation retries end before macOS's last
   remembered-arrangement re-apply; the window rode the built-in into
   its parked spot. Now a standing 5 s rescue for the whole session,
   acting only when the window sits on a desktop the user cannot see.
2. `ScreenCapture` silently fell back from excluding-the-overlay to
   excluding-the-whole-app when SCShareableContent had not yet
   enumerated the just-created overlay window — erasing the settings
   window from the glasses' own capture. Now retries enumeration
   (3 × 0.7 s) and logs if the wide fallback is ever taken.

Open: what flips WindowServer between the fast and slow phases, and
how to pin it fast (eligibility iteration: colorspace, Game Mode,
window level; or CGDisplayCapture exclusive mode). The HUD toggle is
the tool for whoever picks this up.

Correction (next morning): the "HUD absent from screencapture while
fast" hint above is void — those sessions had no HUD at all. The
developerHUDProperties API is a silent no-op on this machine however
it is applied; only the MTL_HUD_ENABLED environment produces a HUD,
and it must be set before Metal loads. The app now setenv's it for
itself at process start from the persisted toggle (so the toggle takes
effect at the next session start). Whether the fast phase is Direct
remains unread.

## The image-quality pipeline, and the temporal verdict (2026-08-14)

Four processing stages were added in one evening (the SpaceWalker
feature safari having previously yielded only features, not image
logic):

1. **Sharpen** — unsharp mask clamped to the local 4-neighbour min/max
   (the clamp is what prevents halos). Counteracts bilinear's softening
   under head-tracked sub-pixel drift. Slider, all desktop paths.
2. **Crisp sampling** — Catmull-Rom in 9 bilinear taps instead of plain
   bilinear. Matters under magnification; ~identical at 1:1.
3. **Linear-light filtering** — the capture is wrapped as
   `bgra8Unorm_srgb` so texels decode to linear *before* the bilinear
   weights apply; the drawable re-encodes on write. Pipelines exist in
   both formats, picked per frame from the drawable's actual format, so
   the live toggle can never mismatch. Eye-care/peek multipliers are
   raised to 2.2 in linear to keep the tuned feel.
4. **Temporal supersampling** — TAA-lite: scene offscreen, MRT
   accumulation (drawable + ping-pong history), reprojection as a pure
   3×3 direction rotation (rotation-only camera ⇒ depth-free and exact),
   3×3 neighbourhood clamp against ghosting, α = 0.88.

**Temporal verdict: rejected as default, kept as a toggle.** At this
panel's 1:1 mapping the accumulation reads *slightly blurrier* than
single-frame — first with bilinear history (blur compounds per resample,
the classic TAA failure), and still, milder, after the standard cure
(Catmull-Rom history resampling). The head's micro-motion supplies
sub-pixel phases, but each reprojection resample costs more detail than
the averaging recovers on static text at native scale. GPU cost was
irrelevant (60 fps, 0 slow throughout). Would be worth revisiting only
where the desktop is minified (mirror mode), where the same averaging
that softens 1:1 text suppresses aliasing instead.

Also decoded from SpaceWalker's binary during this pass: its "Adaptive
VSync" is `CAMetalLayer.setDisplaySyncEnabled:` (ours now has the same
toggle); its "Reduce Motion Blur" traces only to a stored preference —
consumer unknown — and our `motionLock` already chases that goal.

**Sharpen verdict (2026-08-15): rejected at 0.35 by eye — "ภาพกระตุก
เวลาหันหัว".** Static text pops, but under head rotation the desktop
crosses sub-pixel offsets every frame and sharpening amplifies the
resulting crawl into visible judder. Slider stays (default 0). If
sharpening is ever revisited, gate it by angular velocity — full
strength only while the head is still, fading to zero during turns
(the same insight as motionLock, applied to the kernel instead of the
anchor).

**Correction (same day): sharpen exonerated — the judder was Adaptive
VSync.** The user had flipped Adaptive VSync on while exploring Tuning;
with the render already locked at the panel's 60, disabling display
sync buys nothing and every head turn drags a tear line through the
image, which reads as กระตุก. VSync off → judder gone → user pushed
Sharpen to 1.0 and kept it. Standing advice now in the caption: leave
Adaptive VSync off unless frames are actually being dropped — at a
steady 60/0 it is pure downside on this panel.

## The supersampling experiment that never ran (2026-08-15)

ROADMAP item 1 was the one image-quality idea that adds *real* detail
instead of massaging what exists: build the 2nd desktop at 1920×1200
points on a 3840×2400 px Retina backing, let macOS render text at 2×,
and let our Catmull-Rom minify it 2:1 onto the panel. The trap was found
before it could bite — `ScreenCapture.start` capped capture width at
3008 px, so a 3840 px desktop would have been silently downscaled back
and the experiment would have measured nothing. Two commits shipped in
three minutes: the cap became a `maxWidth:` parameter with a
capture-size log line (`8cb44af`), then a `r1920x1200hi` case, a
`captureMaxWidth` that lifts the cap only for a hiDPI virtual desktop,
and a sixth segment in the Desktop-size picker (`55c18fb`).

Then the pacing log fell off a cliff (times below are the log's UTC
stamps, dated 2026-08-14 — the small hours of the 15th locally, UTC+7,
minutes after the two commits landed). Steady
60/0 through 17:39:16Z,
then 41 fps (136 slow), 49, and a fourteen-minute floor of 30-38 fps with
230-300 slow frames per 10 s window, bottoming at a flat 30/300 — the
signature of every frame missing its flip. Low Power Mode was off, the
machine was on AC, and the app log is silent through the whole stretch:
no capture restart, no mode change, no error. The user blamed the new
option.

**The 2× path never ran.** There is no 3840×2400 capture line anywhere in
the log — the only `capture:` lines that session read 1920×1080 @ 60 Hz
from display 2, the plain glasses mirror. What actually starved
WindowServer was the machine itself: the Task-2 build compiling
alongside several Claude helper processes, exactly the choke point the
roadmap named as the *risk* of the experiment, arriving on its own. The
precursors say the same thing more precisely — 71 and 78 fps *avg* at
17:10:48Z and 17:13:11Z, over-60 averages on a 60 Hz panel, which is
arithmetically impossible unless the 10 s pacing timer itself was late;
the sampler was being starved before the renderer was. When the load
ended the session came back to 55-59 and then a clean 59-60.

**Verdict, verbatim:** "จริงๆ คิดว่าอาจจะเกินจำเป็นนะ ทำให้เฟรมตกโดยใช่เหตุด้วย
โหมดนี้ไม่เวิร์ค" — overkill, drops frames for no reason, this mode
doesn't work. The frame-drop half of that is wrong on the evidence
above, and it is the second time in two days that a bystander nearly
took the blame for something else (Sharpen was the first, exonerated
when Adaptive VSync turned out to be the tear source). But the rest of
the verdict stands on its own and the option is gone: overkill for a
daily driver that is plain 60 Hz mirror; the sixth picker segment made
the Settings window content overflow and clip (five segments fit, six
did not — seen in the user's screenshot); and the 2nd-desktop mode
itself carries the friction of arranging every window onto an empty
desktop by hand, which no amount of extra sharpness repays.

Two lessons worth keeping. **Measure before you accuse** — a feature
that has never executed cannot be the cause, and the capture-size log
line added for this experiment is what settled it in one grep; it stays,
along with the `maxWidth:` parameter (default 3008), so a future retry
is a single enum case away. And a UI one: **the segmented Desktop-size
picker is at capacity.** Five options fit the Settings window; a sixth
overflows it. Any further resolution needs a different control — a
menu, or a separate "2×" toggle beside the picker — not another segment.

## Ultra-Wide 21:9 moves in, the 2nd desktop moves out (2026-08-15)

The 2nd-desktop capture source is gone. It had been the sharpest option
on paper — a virtual desktop matched to the panel, nothing downscaled —
and in practice every session opened with the same chore: drag each
window onto an empty screen by hand. Its picker was also the thing that
overflowed the Settings window during the supersampling episode above.
So the source was retired and its single keeper was carried across:
**Ultra-Wide 21:9 is now a toggle inside Glasses-only** (`14774f7`,
`c5792b4`, `cf52c9a`; spec and plan under `docs/superpowers/`).

The mechanism is SBS-60's arrangement shape with the stereo panel left
out. A 2560×1080 @ 60 Hz virtual display is created and made the wall
main; the glasses' own display is parked showing nothing but the
overlay; the built-in is mirror-slaved to the working display, so the
laptop shows what the glasses show and windows opened before Start
follow you in instead of being stranded. The side screens are suppressed
— the wide desktop *is* the wall. The watchdog was taught to defend that
arrangement rather than fight it, which is the whole difference between
this and a display-config tug of war.

Measured live, first real session (log stamps are UTC, 2026-08-14T19:0x,
which is the small hours of the 15th locally):
`capture: 2560×1080 px @ 60 Hz from display 234` — a real virtual
display, at the size on the tin. The watchdog settled in about 15 s (one
one-shot dock bounce, then window rescues for Safari, Claude, LINE and
Finder) and then went completely quiet for a 65 s watch window. Pacing
locked at 60 fps, 0 slow frames, on AC. No errors anywhere in the log.

**Signal-level 21:9 is closed.** Before settling for a virtual display,
the panel itself was asked: `CGDisplayCopyAllDisplayModes` with
`kCGDisplayShowDuplicateLowResolutionModes` against the glasses (vendor
`0x3054`, model `0x4753`) returns 21 modes, every one of them 16:9 or
4:3, none wider than aspect 1.78, topping out at 1920×1080. There is no
2560×1080 to select, and macOS offers no way to synthesise one. On this
platform 21:9 exists only as a virtual display. EDID overrides — the
CRU-style route that would make the panel itself claim a wide timing —
remain a Windows-port topic, as ROADMAP already says.

**One open thread: fullscreen video on a virtual display.** With the
capture source set to the Ultra-Wide desktop, putting a video into
native fullscreen makes the image disappear. Plain glasses-only
fullscreen — which captures the physical display — works. That is the
observation; the root cause on virtual displays is not diagnosed, and
nothing here should be read as a theory. The workaround that keeps 21:9
is YouTube's theater mode (`t`) with a maximized window; the alternative
is to watch in plain glasses-only. This also corrects the ROADMAP's
Cinema mode item (then 13, now 14),
which had stated the crux as SCK's inability to capture native
fullscreen video *at all* — the blanket form is wrong, and the item now
carries the precise one.

Also fixed on the way out: the status line read
`displays.glassesPixelSize` unconditionally, so an Ultra-Wide session
streaming 2560×1080 announced itself as "Running — 1920×1080 @ 60 Hz".
Working-desktop sessions now report the desktop they actually capture.

**Verdict: KEEP.** The obvious objection to a 21:9 screen is that 16:9
video letterboxes on it, and the user waved it off — verbatim: "ยังไงเราก็
ปรับ zoom เข้าออกอยู่แล้วไง แล้วก็หายซ้ายขวาได้อยู่แล้ว ถึงขนาดจะเลยจอ แต่ก็หันได้"
— they zoom the virtual screen in and out as a matter of course, and
they turn their head left and right, even past the edge of the FOV. A
fixed frame is a desktop-monitor problem; in a headset the frame moves
with you.

*(Resolved — see "The fullscreen black had two layers" below.)*

## The fullscreen black had two layers (2026-08-15)

The open thread above — native fullscreen on the Ultra-Wide desktop
turns the glasses pure black while video and audio keep playing — took a
night to unpick, and the answer was two independent faults stacked on
each other. One was ours and is fixed. The other was never ours, and it
is the one the user actually saw.

The instruments first, because the whole diagnosis hangs on them. Two
throwaway probes in `/tmp`: **fsprobe**, which takes an
`SCScreenshotManager` frame of *every* display once a second and reports
mean luma, and **fsstream**, which stands up two live `SCStream`s cloning
the app's own filter and configuration. Between them they can answer the
only question that matters when a picture goes black: is the content
black, or is our copy of it stale? (Log stamps below are UTC,
2026-08-14T19:3x–20:5x, which is the small hours of the 15th locally.)

**Layer 1 — our stream froze, and kept pretending it hadn't.** On
fullscreen-Space engagement the app's long-lived `SCStream` went on
delivering `.complete` BGRA 2560×1080 IOSurface frames at a full 60 fps,
every one of them stale: mean luma pinned at exactly 32.5 for 16
seconds, with sparse content refreshes every 6–16 s. In those same
seconds an independent screenshot, and a stream created fresh on the
same display with the same filter, both saw the live video. So: not a
black desktop, not a broken filter — a frozen stream that lies about it,
which is the worst shape a bug can take, because every health signal we
had read "fine".

Three false leads died on the way. **The filter-exclusion hypothesis**
(our overlay window is excluded from the filter; maybe fullscreen makes
the exclusion swallow everything) — disproved, a fresh stream with a
byte-identical filter saw live pixels. **The pixel-format hypothesis**
(maybe fullscreen video flips the surface to a planar format our
renderer silently drops) — disproved by the instrumentation, the format
never changed; that logging has now been removed. And **the NSWorkspace
observer**, which was the plan for triggering recovery:
`activeSpaceDidChangeNotification` *never fires* for these transitions.
Not late, not debounced away — measured, with an observer that logged
unconditionally, and it logged nothing. A 1 Hz poll of
`CGSManagedDisplayGetCurrentSpace` (`@_silgen_name`, `SpaceWatch.swift`)
in the existing watchdog caught every single transition instead:
`space: display space changed (1 → 1245)`. The dead observer and its
debounce machinery are gone; the poll is the trigger.

Recovery took two attempts. A hard stop/start bounce restored live
frames for about 6 seconds and then re-froze — the new stream inherits
the same fate. What worked came from **reading the vendor's own
SpaceWalker binary**, which runs the same SCK + `CGVirtualDisplay` stack
without this bug: it implements `streamDidBecomeActive`/`Inactive` and
recovers by pushing a fresh content filter onto the *live* stream via
`updateContentFilter`. Doing the same keeps capture live through the
entire fullscreen window — measured, luma varying 15–57 continuously, no
freeze, no black gap and no dropped-frame-clock reset. Worth noting that
`streamDidBecomeInactive` (macOS 15.2+) never fired for us either; the
logging stays, because a callback that is silent today is evidence
tomorrow.

**Layer 2 — the black itself was a system setting, not a bug.** This
machine runs Mission Control's *"Displays have separate Spaces"*
**disabled** — `defaults read com.apple.spaces spans-displays` returns
`1`. With Spaces spanning displays, *any* native fullscreen blacks out
every other display at the WindowServer level, and that includes the
glasses display living under our overlay. That is why fsprobe measured
**exactly 0.00** luma on the glasses display while the app was rendering
happily at 60 fps: there was nothing to render *from*, and no amount of
capture fixing would have changed it. It is also why SpaceWalker's
binary explicitly checks `NSScreen.screensHaveSeparateSpaces`. The fix
is a user setting plus a logout; the user has been told. **Expected to
resolve; verify by eye after re-login.**

One correction to yesterday's note. "Plain glasses-only fullscreen
works" is not in tension with any of this — there the fullscreen video
occupies the very display our overlay covers, so the spanning blackout
lands on the *other* displays, not on the one being looked through.
Same rule, different seat.

The lesson is the one this file keeps relearning, in a new costume:
**when a picture is black, measure the source and the copy separately.**
Had the glasses-display screenshot been taken on night one, layer 2
would have been named in a minute — and layer 1, a genuine bug worth
fixing on its own merits, would still have been sitting there,
undiscovered, waiting for the day the setting was flipped.

**Addendum, 2026-08-15 (later): the setting will not be flipped.** The
user vetoed it, and the reason is good enough to close the question:
"Displays have separate Spaces" is off on this machine *on purpose*,
because turning it on breaks the 3-screen side-screen wall — windows can
no longer straddle displays, and every display grows its own menu bar.
The wall is the daily driver; a video workaround is not worth taxing it.
The design consequence is therefore permanent: on this machine, native
fullscreen on a virtual-display source is black by OS design, and no app
change reaches it. The remaining route to fullscreen-like video on
Ultra-Wide is **per-window capture** — an `SCContentFilter`
`desktopIndependentWindow` on the video window itself, drawn as a big
curved screen, which never involves a fullscreen Space at all. Until
that exists, theater mode (`t`) plus a maximized window is the answer.
