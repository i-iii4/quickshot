# QuickShot Product Contract

This document is the product contract for the screenshot capture flow. Any
implementation that violates these rules is considered a regression, even if it
passes compilation.

## Capture Flow

1. `Command-Shift-4` starts exactly one capture session. Repeated triggers during
   an active session are ignored.
2. The captured pixels must represent the screen state at the beginning of the
   capture gesture, before QuickShot shows selection UI or activates overlay
   windows.
3. The visible selection overlay must be shown only with a frozen backdrop. The
   user must not see a live desktop under the selection UI for seconds and then
   watch it switch to a frozen image.
4. If the user presses the hotkey and immediately starts dragging, QuickShot must
   preserve the gesture intent. The user must not have to release the mouse and
   start again.
5. The final cropped image must always come from the frozen frame used for the
   selection, not from a second live capture after the overlay appears.
6. QuickShot UI must never appear in the frozen frame or final screenshot:
   selection overlay, custom cursor, selection frame, hub, thumbnails, settings,
   or menu-bar helper windows are all excluded by hiding them before capture or
   by a proven ScreenCaptureKit exclusion filter.
7. Normal warm capture should feel immediate. The target budget for the
   hotkey-to-frozen-overlay transition is below 250 ms on the primary display.
   Anything above 400 ms must be logged as a performance warning with phase
   timings. A 2-3 second transition is a product failure.
8. The hotkey path must use the ScreenCaptureKit stream cache. It must not call
   one-shot `SCScreenshotManager` capture from `CaptureController`; if a hotkey
   arrives during startup warmup, the session may wait for a cache `late hit`,
   but it must not silently switch to the slower screenshot API path.

## Overlay

1. There is one overlay window per screen, matching the exact `NSScreen.frame`.
   The overlay must not be shifted by Dock, menu bar, or `visibleFrame`.
2. The overlay is modal to the current Space. If the active Space changes during
   selection, the capture is cancelled and all overlay/cursor state is restored.
3. The backdrop is static for the whole session. The unselected area may be
   dimmed, but the selected area shows the same frozen pixels at full contrast.
4. `Esc` cancels the active session from any screen.
5. Completion dismisses every overlay window exactly once and restores all cursor
   suppression state.

## Cursor And Selection Tool

1. The visible cursor in selection mode is QuickShot's custom vector crosshair.
   The system pointer must not be visible at the same time.
2. The custom cursor does not change size, shape, or anchor during drag.
3. The selection frame and the cursor are one visual system: same stroke widths,
   same halo/core colors, round caps, and a small clean separator where the frame
   continues the cursor arms.
4. There is no dot, handle, bridge, duplicate pointer, or flicker on mouse move.
5. The frame remains geometrically stable for all drag directions and small
   selections. It must not overlap the cursor in a way that creates visual noise.

## Result And Thumbnail Tray

1. A completed selection smaller than 3 x 3 points is ignored.
2. A valid selection produces exactly one thumbnail and copies the image to the
   clipboard through the existing clipboard path.
3. Hub click still toggles thumbnail collapse/expand.
4. Hub action buttons remain clickable and do not toggle collapse/expand
   accidentally.
5. The tray/hub position is based on full screen frames, not safe areas; it may
   intentionally overlap Dock or menu bar.
6. The hub is a Vercel/Geist-inspired command surface: compact state uses one
   dark pill with one outer stroke, not stacked translucent rings or bridges.
7. Hover reveal exposes three short Title Case actions: `Delete`, `Save`, and
   `Copy`. Longer intent is carried by accessibility labels, not visible text.
8. Action pills must become clickable as soon as their label is fully visible
   during reveal, and a press must still complete if the shell receives a mouse
   exit before mouse-up.

## Observability And Regression Gates

1. The capture path logs phase timings for trigger, ScreenCaptureKit content
   enumeration, per-display screenshot, overlay creation, selection completion,
   and final crop.
2. Timing logs must not contain screenshot content or user text from the screen.
3. Tests must cover pure geometry and interaction contracts where possible:
   cursor/frame geometry, crop math, hub clickability, action clickability, and
   hub reveal states.
4. Manual verification after any capture-flow change must use a freshly restarted
   `QuickShot.app` process. A successful build is not evidence that the running
   menu-bar app changed.
5. Runtime verification must include at least one completed drag-selection path,
   not only `Esc` cancellation. The completed path must prove crop completion,
   clipboard output, cursor restoration, and absence of overlay/cursor pixels in
   the final image.
