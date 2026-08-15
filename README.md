# QuickShot

QuickShot is a macOS menu-bar screenshot tool for fast area capture by hotkey.
The product target is direct manipulation: the user should be able to press the
hotkey and start selecting immediately.

## UX Contract

1. Press `Command-Shift-4`.
2. QuickShot captures the current displays before showing or activating any of
   its own windows.
3. Selection mode then appears over the frozen hotkey-time image. There is no
   dark waiting layer, progressive backdrop installation, or stale frame.
4. The only selection-mode chrome before drag is QuickShot's custom cursor; the
   system pointer is not visible at the same time.
5. When the user starts dragging, the established selection frame appears.
6. The lightweight overlay appears
   inside the selected area, not outside it.
7. The area outside the selection stays undimmed.
8. Releasing the mouse crops the already captured image without a second screen
   capture.
9. A valid selection creates one thumbnail and copies the screenshot to the
   clipboard.
10. `Esc` cancels selection and restores the normal cursor/UI state.

The captured image must never be an old cached screenshot. If QuickShot cannot
produce a fresh result for the completed selection, the attempt should fail
cleanly instead of showing stale pixels.

QuickShot UI is excluded through window sharing protection. The tray stays
visually stable instead of blinking out and back in at capture time.

## Selection Visuals

- The visible pointer in selection mode is QuickShot's own crosshair. The system
  pointer must not be visible at the same time.
- The cursor and the selection frame are one visual system: same stroke language,
  same contrast model, and a clean separator where the cursor meets the frame.
- The cursor does not change size, anchor, or shape during drag.
- There is no dot, handle, bridge, duplicate pointer, or flicker.
- The inner overlay is light. It helps the user read the selected region without
  hiding the screen content or turning the whole display into a dark mask.
- The overlay appears only after selection begins and disappears when the
  selection is cancelled or completed.

## Tray And Hub

- When there is at least one screenshot, QuickShot shows the compact
  icon+label hub near the screen corner.
- Clicking the hub collapses or expands screenshots.
- Hovering the compact hub temporarily reveals a collapsed tray without
  changing its click-owned collapsed state. The hub and every visible card
  form one hover session, so moving the pointer from the command row onto a
  screenshot keeps both the row and the cards expanded.
- The hover region is one continuous island: the visible hub row, every
  visible card, and the gaps between them (up to `20pt`) are bridged, with an
  `8pt` shield around the geometry and extra exit hysteresis. Moving slowly
  across a gap never drops the session, and pointer routing for the
  full-screen host follows the same island, so tracking never dies mid-path.
- Leaving the complete hover island starts a `180ms` grace period. Returning
  to the hub or any card cancels the pending collapse.
- A new screenshot does not permanently expand a collapsed tray. It fades into
  the nearest slot, remains fully visible for `1.2s`, and fades out again. Hover
  holds that acknowledgement indefinitely and the normal exit grace starts
  only after the pointer leaves.
- Existing screenshot cards keep their positions when a new one arrives. The
  new card occupies the next free slot away from the hub instead of reflowing
  the stack.
- The hub position is based on the full screen frame, not the Dock/menu-bar safe
  area.
- Hover reveal exposes three independent House command buttons in a token-spaced row: `Close`,
  `Save As`, and `Copy All`. They are icon-only; the command name appears as a
  tooltip — `500ms` cold, instant warm retargeting between neighbouring
  commands. QuickShot draws the tooltip itself — system help tags never fire
  for an inactive accessory app — typeset on the House small-control register
  with token metrics and surface-sampled colors; the window is
  capture-excluded and pointer-transparent, and any row relayout dismisses
  it. The core `Hide`/`Show` button keeps its icon+label form.
- Hover fades in one rounded House Dark bubble around the complete command row;
  it is absent at rest. Its `14pt` radius and `6pt` inset are concentric with
  the buttons' `8pt` radius. Neutral commands use the dark `secondary` variant
  instead of the light dark-theme `primary` variant.
- Hub, thumbnail, pinned, and settings commands are real Native
  SDK controls rendered from one fixed House Dark token register. AppKit owns only window
  hosting and system chrome.
- The menu bar entry opens a plain system `NSMenu`. The design system covers
  the floating chrome QuickShot puts over other applications; on a surface the
  system owns, platform behavior — keyboard navigation, VoiceOver, press-drag
  selection, status-item highlight, placement — is worth more than brand.
- Every rounded control has exactly one Native SDK chrome owner. The hub's
  animated core stretches that owner's raster with preserved caps; transparent,
  pointer-free foreground slices carry only its icon and text. Stroke geometry
  is aligned to physical display pixels and rendered with coverage
  antialiasing, so Retina scaling cannot create doubled or jagged borders.
- Hover, pressed, and click dispatch travel through the Native SDK runtime;
  visible labels are not used as action identifiers.
- Native SDK `button-group` is reserved for model-owned exclusive choices such
  as tray position; independent commands never use group chrome.
- The visual scheme is fixed to House Dark. System High Contrast and Reduce
  Motion settings are projected into the embedded runtime and repaint the
  complete surface.
- Empty transparent tray space must not steal clicks from real controls.
- Tray collapse, card opacity/shadow, and chevron rotation derive from one
  interruptible progress source. Card insertion, removal, and reflow use one
  collection transaction, while count changes use a vertically clipped
  odometer transition.

Visual references are stored in `reference/screenshots/`.

## Tray Scrolling

- When the cards no longer fit, the strip scrolls; nothing is dropped for lack
  of space. Cards past either edge collect into a stack with a shrinking step,
  fading and scaling, so the stack itself says that more exists.
- Content follows the fingers. A trackpad gesture applies its delta directly; a
  mouse wheel reports line units, so a notch is scaled to points instead of
  moving the strip by a single point.
- The strip follows the newest capture until the user scrolls away, and every
  new capture re-arms that following.
- Past an edge the strip resists with a rubber band and returns with a short
  ease-out; a continued pull collapses the tray. A phase-less mouse wheel gets
  hard edges and no rubber band.
- A scroll frame only moves cards. Card widths, hub position and resize modes
  are recomputed on layout changes, never per scroll event.
- Exactly one card shows its hover buttons: the one under the pointer. A card
  that leaves the pointer during a scroll never receives `mouseExited`, so the
  hover owner is reassigned after every scroll frame.

## Annotation Editor

- Double-clicking a card opens the editor for that screenshot.
- The toolbar is icon-first in the House register: eleven tools, then history,
  scan, save and copy. Colour swatches, stroke weight and fill appear only
  while something is selected; rotate appears in crop mode. With nothing
  selected the toolbar shows at most sixteen controls.
- Every control carries an accessible name that also serves as its hover
  tooltip; visible one- and two-letter codes are prohibited.
- Text and counter digits are drawn in the same orientation on screen and in
  the exported file.
- One user gesture is one step of undo history. Changing the selection is not
  an edit and never records a step.
- Hiding sensitive data has exactly one tool: an opaque bar. Blur and
  pixelation are rejected (`X-8` in the annotation requirements).
- Scanning for sensitive data reports findings only. Nothing found shows no
  window at all, and closing the editor cancels a scan in flight.

## Screenshot Storage

- With autosave on, screenshots are written to `~/Pictures/QuickShot` and
  expire after the chosen retention (a day, a week, a month, forever). Expired
  files are deleted permanently, not moved to the Trash.
- With autosave off, screenshots live in the tray and on the clipboard only.
- Saving in the editor rewrites the file, marks the card `Edited`, and every
  later delivery — clipboard, drag, export — uses the edited version.

## Capture Implementation Status

QuickShot uses a direct, session-owned CoreGraphics snapshot at the hotkey
moment, then presents the established custom cursor and frame over immutable
per-display backdrops. Mouse-up crops that same image; there is no stream cache,
system capture subprocess, temporary PNG pixel source, or second screenshot.
Post-crop clipboard files are sequence-owned delivery artifacts with explicit
card, pasteboard, drag, and pin leases. Encoding happens once per screenshot;
unleased files are removed on replacement, shutdown, or crash recovery. Drag-out
works from the first visible frame: prepared cards publish PNG/TIFF/file URL
directly, while a card that is still encoding publishes a standard AppKit PNG
file promise backed by the same one-time preparation task.

After frozen pixels are ready, the selector acquires foreground ownership and one
session-owned AppKit cursor lease before revealing its custom crosshair. The
excluded QuickShot tray stays visible between the frozen backdrop and selection
chrome, but its full-screen host accepts pointer events only directly above visible
controls. A finite scrollable viewport keeps every screenshot reachable; new
captures always enter the visible range instead of creating overflow windows.

The 24 July 2026 remediation is implemented: early gestures and Escape are
session-owned, delivery is monotonic, resources are bounded, protection fails
closed, tray state is model-owned, and production/tests compile under Swift 6
complete strict concurrency. The headless suite now includes 100 randomized
delivery lifecycles, 100 fake-backend lifecycles, and a 100-artifact cleanup
stress test.

Release still requires the opt-in manual runtime and latency matrix on the exact
build. Automated success is not treated as proof of cursor appearance,
fullscreen Spaces behavior, physical multi-display behavior, or p95 latency.

See `CAPTURE_ARCHITECTURE.md` for the component boundaries, migration plan, and
definition of done.

## Native UI Design System

Native SDK component provenance, tokens, documented compositions, the complete
catalog, and reusable markup contracts live in the independent project:

```text
/Users/i_iii/Проекты/native-ui-design-system
```

The dependency is separately versioned in the private
`i-iii4/native-ui-design-system` repository. `NativeUIDependencies.lock` pins
design-system revision `bcfa1be8c3c4e219bcd79aaf9219a79c34933f22` and Native
SDK `0.5.4`; build and test fail on any mismatch or tracked dependency change.
QuickShot does not keep a private copy of the catalog or validator.

Configure any clean checkout once:

```bash
/absolute/path/to/native-ui-design-system/scripts/bootstrap.sh
./scripts/configure-native-ui-dependency.sh \
  /absolute/path/to/native-ui-design-system
```

CI resolves the same revision with a read-only deploy key. Production builds
and the default regression suite link the Native UI library in `ReleaseFast`,
so motion and render budgets exercise the shipped path.

## Build

```bash
./build.sh
```

The build creates and verifies a signed staging bundle before atomically
replacing `QuickShot.app`. A compiler, signing, or installation failure leaves
the previous valid app untouched.

## Test

```bash
./scripts/test.sh
```

The headless suite requires `ripgrep`; CI provisions it explicitly.

The default suite is headless and does not open windows over the active screen.
The separate live-window click probes remain explicit:

```bash
QUICKSHOT_RUN_LIVE_UI_TESTS=1 ./scripts/test.sh
```

Runtime checks that post synthetic hotkeys or mouse events must stay opt-in:

```bash
QUICKSHOT_ALLOW_SYNTHETIC_INPUT=1 ./scripts/verify-capture-runtime.sh
```

Prefer log-only verification when working on the user's active machine.

Visual checks render real surfaces to PNG so the result can be looked at
instead of inferred:

```bash
./scripts/run-snapshot.sh 1200 /tmp/toolbar.png            # editor toolbar
./scripts/run-snapshot.sh 1200 /tmp/toolbar.png selected   # with a selection
python3 ./scripts/run-snapshot-canvas.py /tmp              # canvas: text, counters
python3 ./scripts/run-one.py EditorDrawingTests.swift      # one suite, fast loop
```

## Run

```bash
open ./QuickShot.app
```

Run the app through `open` or Finder so macOS attaches Screen Recording
permission to the bundle.

## Documents

- `PRODUCT_CONTRACT.md` - UX requirements that define regressions.
- `ANNOTATION_REQUIREMENTS.md` - product requirements for the annotation
  feature, based on a market review. Levels 1 and 2 are implemented; level 3
  and the rejected set (`X-1`…`X-8`) are not.
- `SYSTEM_REQUIREMENTS.md` - product requirements outside annotation: tray
  scrolling, on-disk storage with expiry, and the edited-screenshot lifecycle.
  Implemented.
- `PLAN.md` - work plan for the requirements above: packages, dependencies,
  and acceptance gates. No schedules, scope only.
- `CAPTURE_ARCHITECTURE.md` - capture decision, transition status, and plan.
- `DEVLOG.md` - dated engineering notes.
