# rokid-spatial

A spatial display driver for the **Rokid Max** on Apple Silicon Macs.

Rokid does not ship AR Mode for macOS — their own compatibility page lists
MacBooks as screen-casting only. So on a Mac the glasses are just a 1080p
external monitor strapped to your face: the image is rigidly head-locked, it
never sits still relative to the room, and it runs at 60 Hz. This project
builds the missing piece.

## What it does

There are two things it can show, chosen with the **Show** picker:

**Glasses only** — the recommended one. There is exactly one desktop, it lives
on the glasses' own 1920×1200 display, and the MacBook screen goes dark.
Everything else about this mode falls out of that one fact: no second screen
for windows to get lost on or the pointer to wander off to, no display
arrangement to fight macOS over, and quitting barely has to restore anything.
It works by *embracing* the mirroring macOS keeps trying to impose — the
built-in display just mirrors the glasses — and capturing the glasses' own
display with the overlay window excluded from the capture, which is what
breaks the would-be feedback loop. The settings window stays visible inside
the glasses, so everything remains adjustable while wearing them.

**Mirror Mac** — your actual screen, floating in front of you. Sharpness
depends entirely on your Mac's resolution: the virtual screen spans roughly
1235 panel pixels, and a 1680-point desktop squeezed into that arrives at 73%
of the size the text was drawn for. Lower the Mac's resolution or enlarge the
virtual screen until the sharpness readout reaches 1.0. Requires an extended
(un-mirrored) arrangement, with everything that entails.

A third source, **Separate desktop** — an empty second desktop sized to the
glasses — existed until 2026-08-15 and is retired. It measured sharper than
mirroring (1.23× against 0.74×), but every session began with dragging windows
onto an empty screen by hand, and no amount of sharpness repaid that. Its one
keeper survives as a glasses-only option:

**Ultra-Wide 21:9** — a toggle under **Glasses only**. The session works on one
panoramic 2560×1080 desktop instead of the three-screen wall: a virtual display
becomes the main screen, the built-in mirrors it, and the glasses show only the
overlay. Windows you already had follow you in, because the MacBook desktop is
merged rather than hidden. Best paired with **Curved screen**, so the edges sit
the same distance away as the centre. 21:9 is only available this way — the
panel's own EDID has no wide modes (see RESEARCH.md).

### Glasses-only mode: the fine print

Three system things try to draw on top of the overlay, and each needed a
different answer:

- **The hardware cursor** would float head-locked over the scene. It is a
  hardware plane composited above every window — no window level beats it —
  so the system cursor is hidden outright (which also stops ScreenCaptureKit
  drawing it into frames) and the renderer paints its own sprite at the real
  mouse position on the virtual screen. Hiding is re-asserted at 10 Hz
  because any app changing the cursor shape makes it visible again, and the
  hide counter dies with the process, so even a crash cannot strand you
  cursorless.
- **System HUD windows** — the screen-recording pill, Control Centre panels,
  volume bezels — sit above the normal overlay level. The overlay runs at the
  maximum window level in this mode, which buries their head-locked copies;
  they remain perfectly usable inside the captured desktop.
- **The purple screen-capture privacy dot** (top-right corner) is drawn above
  anything an app can reach, cannot be covered, and that is deliberate — it
  is how macOS guarantees no app records the screen invisibly. Every screen
  recorder shows it. The only sanctioned removal is Apple's
  `persistent-content-capture` entitlement, which requires case-by-case
  approval. It stays.

The built-in panel is dimmed to zero while running (restored on every exit
path) rather than switched off — the brightness keys always work if anything
goes wrong.


- **Reads the glasses' IMU directly** over their vendor HID interface at
  ~440 Hz, and fuses it into a head-orientation estimate
- **Unlocks 1920×1200 @ 120 Hz**, double the default 1080p60 refresh rate at
  higher resolution
- **Renders the desktop as a virtual screen in space**, in two modes:
  - *smooth follow* — the screen trails your head with a deadzone, so small
    movements don't move it and large ones bring it along
  - *world-anchored* — the screen stays put in the room while you look around
- **Adjustable screen distance, size and height**

### Why no stereo mode?

The panel also supports 3840×1200 @ 90 Hz side-by-side, and an earlier
version exposed it. It was removed after real use: the disparity at a 2.5 m
screen distance is only about 1.4° — barely perceptible — while 120 against
90 Hz is obvious the moment you turn your head, and in glasses-only mode SBS
forces the whole desktop to 3840×1200, which halves per-eye sharpness. Three
losses, no felt gain. The stereo render path survives in the code and the
protocol side is documented in [PROTOCOL.md](PROTOCOL.md), should it ever
earn its way back.

## Status

| Piece | State |
|---|---|
| USB/HID protocol reverse-engineering | ✅ done, see [PROTOCOL.md](PROTOCOL.md) |
| IMU reader (`RokidKit/IMU.swift`) | ✅ working, ~440 Hz |
| Sensor fusion (`RokidKit/Fusion.swift`) | ✅ working, drift ≈ 3.3 °/min in yaw |
| Display mode control (`RokidKit/DisplayMode.swift`) | ✅ working, mode 4 verified |
| `rokid-probe` — raw packet dumper | ✅ |
| `rokid-orient` — live orientation readout | ✅ |
| Metal / ScreenCaptureKit renderer | ✅ builds and runs |
| Menu-bar GUI, global hotkeys | ✅ |
| Glasses-only mode (single screen, own cursor) | ✅ verified in use |
| Settings persistence across launches | ✅ |
| End-to-end use over a long session | ⚠️ needs real-world tuning |
| Windows | ⬜ see [PORTING.md](PORTING.md) |

What's next, and in what order: [ROADMAP.md](ROADMAP.md).

## Running it

```bash
./Scripts/make-app.sh
```

```bash
open .build/RokidSpatial.app
```

An eyeglasses icon appears in the menu bar. Press **Start** in the settings
window. On first run macOS will ask for Screen Recording permission — grant
it, then quit and relaunch, because the capture stream cannot attach
retroactively. Settings — including the chosen mode — persist across
launches.

What starting does depends on the mode. **Glasses only** switches the panel
mode, leaves mirroring exactly as macOS wants it, and dims the built-in
screen; quitting restores brightness and puts the panel back to 2D, and that
is the whole story. **Mirror Mac** — and the glasses-only variants that build a
working virtual desktop, SBS and Ultra-Wide — additionally un-mirror and
rearrange the displays, and restore them on quit.

Two things are deliberately *not* restored on exit from those arrangements,
both learned the hard way:

- **Mirroring is never re-enabled.** The glasses normally arrive as the mirror
  *master*, which deactivates the built-in display — so faithfully restoring
  that state leaves nothing usable to look at.
- **The panel always returns to 2D**, never to whatever mode it was found in.
  Side-by-side only makes sense while something is rendering a separate image
  per eye; without that, each eye gets half a desktop.

### Calibrate once per session

Press **Calibrate** (or `⌃⌥C`), put the glasses down, and leave them alone for
six seconds. This measures the gyroscope's zero offset, and it is the single
biggest thing you can do for tracking quality: yaw drift falls from about
3.3 °/min to **0.14 °/min**. Anchored mode is only really usable afterwards.

Drift cannot be eliminated. These are 3DoF glasses with no camera, and the
magnetometer reads about 108 µT indoors — far outside Earth's 25–65 µT — so it
is too polluted to correct yaw with. Follow mode hides the residue by
continuously easing back to centre; anchored mode does not, by design.

### Getting unstuck

The overlay is opaque, full-screen and always on top. If it stays up while the
desktop underneath becomes unusable, there is nothing left to see or click —
and macOS *will* reinstate mirroring on its own, which deactivates the
built-in display and produces exactly that. Three independent ways out, in
order of how little you need to be able to see:

1. **`⌃⌥Esc`** — emergency stop. Drops the overlay and restores the displays.
   Works blind, and is registered before anything else during startup.
2. **A watchdog**, checked once a second. If the glasses get re-mirrored or
   deactivated, the desktop display switches off, or captured frames stop
   arriving for four seconds, the app tears itself down without being asked.
   Verified by deliberately forcing the fault: it recovered in about two
   seconds.
3. **`./Scripts/rescue.sh`** — kills the app, resets the panel to plain 2D,
   and holds mirroring off while macOS tries to bring it back. Written to be
   typed blind.

Failing all of those, unplugging the glasses restores them.

macOS never forgets that this display pair was once mirrored, and re-applies
that memory — sometimes twice, up to ~10 s late — every time the panel
re-enumerates. Everything that changes the panel mode therefore *watches* for
mirroring to come back and pushes it off until it stays off. On quit that
watch runs in a separate helper process (`--restore-displays`), because a
quitting app literally cannot see the mirroring happen: its display state
stops updating once the run loop winds down.

Every state change is appended to `~/Library/Logs/RokidSpatial.log` — read
that first when diagnosing anything.

### Hotkeys

| | |
|---|---|
| `⌃⌥Esc` | **emergency stop** |
| `⌃⌥R` | re-centre |
| `⌃⌥C` | calibrate the gyroscope |
| `⌃⌥M` | follow ⇄ anchored |
| `⌃⌥-` / `⌃⌥=` | nearer / further |
| `⌃⌥[` / `⌃⌥]` | smaller / bigger |
| `⌃⌥↑` / `⌃⌥↓` | screen up / down |

## Requirements

- Apple Silicon Mac (developed on an M1, macOS 26.6)
- Swift toolchain — Command Line Tools is enough, full Xcode is **not**
  required (shaders are compiled at runtime, so no `metal` compiler needed)
- `brew install libusb`

## Build

Create the local signing identity first — once, ever:

```bash
./Scripts/make-signing-cert.sh
```

Skipping this step works, but the app is then ad-hoc signed, and an ad-hoc
signature's designated requirement is the code's own hash. Every rebuild looks
like a different app to macOS, so Screen Recording permission has to be granted
again each time. With the certificate the requirement becomes bundle identifier
plus certificate, which survives rebuilds. It adds one key to your login
keychain, readable only by `/usr/bin/codesign`, and can be removed with
`security delete-identity -c "RokidSpatial Dev"`.

Then:

```bash
./Scripts/make-app.sh
```

The two standalone tools in `Tools/` build separately. The display-mode tool
is plain C:

```bash
clang -O2 -o .build/rokid-display-mode Tools/rokid-display-mode.c \
  -I/opt/homebrew/opt/libusb/include/libusb-1.0 \
  -L/opt/homebrew/opt/libusb/lib -lusb-1.0
```

And the re-mirror tool `Scripts/rescue.sh` calls at the end, which puts the
glasses back to mirroring the built-in screen, is a single Swift file:

```bash
swiftc -O -o .build/remirror-displays Tools/remirror-displays.swift
```

## Usage

Watch the raw IMU packets and locate fields in them:

```bash
./.build/release/rokid-probe
```

Live head-orientation readout — yaw, per-axis rotation, gyro bias:

```bash
./.build/release/rokid-orient
```

Read or change the display mode:

```bash
./.build/rokid-display-mode get
```

```bash
./.build/rokid-display-mode set 4
```

If the display ever ends up in a state you can't read, `set 0` puts it back —
and unplugging the glasses does too.

## What this cannot fix

The birdbath optics fix the focal distance at roughly 6 m in hardware. Stereo
disparity changes where the screen *appears* to be, but your eyes still focus
at 6 m regardless. If the goal is to reduce focus-related eye strain rather
than to reposition the image, no software on any platform can deliver that on
this hardware.

## Credits

Packet layout and display-mode commands come from
[`badicsalex/ar-drivers-rs`](https://github.com/badicsalex/ar-drivers-rs).
The overall design follows
[`wheaney/breezy-desktop`](https://github.com/wheaney/breezy-desktop), which
does this properly on Linux.
