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

- When there is at least one screenshot, QuickShot shows the compact hub near
  the screen corner.
- Clicking the hub collapses or expands screenshots.
- A new screenshot expands the tray.
- The hub position is based on the full screen frame, not the Dock/menu-bar safe
  area.
- Hover reveal exposes three command pills: `Delete`, `Save`, and `Copy`.
- Per-thumbnail controls use QuickShot command-button styling, not native Liquid
  Glass controls.
- Empty transparent tray space must not steal clicks from real controls.

Visual references are stored in `reference/screenshots/`.

## Interface Model Direction

QuickShot is evaluating stronger interface models for the application shell.
The current candidate is Native SDK (`vercel-labs/native`): not as a screenshot
engine replacement, but as a possible way to get a cleaner component/state/
automation model for the hub, cards, command pills, focus, hover, and click
stories.

Any framework spike must preserve the capture UX contract: immediate selection,
fresh final pixels, no stale screenshots, no tray blink, no duplicate cursor,
and stable clickable controls.

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

## Build

```bash
./build.sh
```

## Test

```bash
./scripts/test.sh
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
- `CAPTURE_REDESIGN_PLAN.md` - short UX-first work plan for the next capture
  rewrite.
- `INTERFACE_MODEL_RESEARCH.md` - Native SDK/interface-model evaluation plan.
- `DEVLOG.md` - dated engineering notes.
