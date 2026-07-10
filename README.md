# QuickShot

QuickShot is a macOS menu-bar screenshot tool for fast area capture by hotkey.
The product target is direct manipulation: the user should be able to press the
hotkey and start selecting immediately.

## UX Contract

1. Press `Command-Shift-4`.
2. Selection mode starts immediately.
3. Before the first drag, the screen remains visually unchanged. There is no
   dark waiting layer and no frozen-preview transition.
4. The only selection-mode chrome before drag is QuickShot's custom cursor.
5. When the user starts dragging, the selection frame appears.
6. The overlay is inverted from the old model: the lightweight overlay appears
   inside the selected area, not outside it.
7. The area outside the selection stays live-looking and undimmed.
8. Releasing the mouse completes the selection. Any capture/encoding delay must
   happen after mouse-up, not before the user can start selecting.
9. A valid selection creates one thumbnail and copies the screenshot to the
   clipboard.
10. `Esc` cancels selection and restores the normal cursor/UI state.

The captured image must never be an old cached screenshot. If QuickShot cannot
produce a fresh result for the completed selection, the attempt should fail
cleanly instead of showing stale pixels.

QuickShot UI is excluded from the final screenshot through the ScreenCaptureKit
capture filter. The tray should stay visually stable instead of blinking out and
back in at capture time.

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
- A new screenshot expands the tray.
- Existing screenshot cards keep their positions when a new one arrives. The
  new card occupies the next free slot away from the hub instead of reflowing
  the stack.
- The hub position is based on the full screen frame, not the Dock/menu-bar safe
  area.
- Hover reveal exposes three independent House command buttons in a token-spaced row: `Delete`,
  `Save As`, and `Copy All`.
- Hover fades in one rounded House Dark bubble around the complete command row;
  it is absent at rest. Its `14pt` radius and `6pt` inset are concentric with
  the buttons' `8pt` radius. Neutral commands use the dark `secondary` variant
  instead of the light dark-theme `primary` variant.
- Hub, thumbnail, pinned, settings, and status-menu commands are real Native
  SDK controls rendered from one fixed House Dark token register. AppKit owns only window
  hosting and system chrome.
- Hover, pressed, and click dispatch travel through the Native SDK runtime;
  visible labels are not used as action identifiers.
- Native SDK `button-group` is reserved for model-owned exclusive choices such
  as tray position; independent commands never use group chrome.
- The visual scheme is fixed to House Dark. System High Contrast and Reduce
  Motion settings are projected into the embedded runtime and repaint the
  complete surface.
- Empty transparent tray space must not steal clicks from real controls.

Visual references are stored in `reference/screenshots/`.

## Current Implementation

The current capture flow follows this UX goal:

1. Make hotkey entry feel immediate.
2. Keep the screen visually normal until the user starts selecting.
3. Draw the lightweight overlay only inside the selected region.
4. Complete capture from the released selection without using stale pixels.
5. Exclude QuickShot UI from the captured pixels without hiding the tray.
6. Preserve tray, hub, copy, close, collapse, and expand clickability.
7. Verify the flow with zero, one, and multiple existing screenshots.

Implementation details are allowed to change freely as long as this UX contract
does not regress.

## Native UI Design System

Native SDK component provenance, tokens, documented compositions, the complete
catalog, and reusable markup contracts live in the sibling project:

```text
/Users/i_iii/Проекты/native-ui-design-system
```

`build.sh` and `scripts/test.sh` call that project's `scripts/check.sh` before
compiling QuickShot UI. Override its location with `NATIVE_DESIGN_SYSTEM_DIR`.
QuickShot does not keep a private copy of the catalog or composition validator.
Production builds and the default regression suite link the Native UI library
in `ReleaseFast`, so motion and render budgets exercise the shipped path. Debug
builds remain available for explicit diagnostics.

## Build

```bash
./build.sh
```

## Test

```bash
./scripts/test.sh
```

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

## Run

```bash
open ./QuickShot.app
```

Run the app through `open` or Finder so macOS attaches Screen Recording
permission to the bundle.

## Documents

- `PRODUCT_CONTRACT.md` - UX requirements that define regressions.
- `DEVLOG.md` - dated engineering notes.
