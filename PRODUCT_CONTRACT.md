# QuickShot UX Contract

This document defines the user experience. Implementation details can change,
but any behavior that breaks this contract is a regression.

## Capture Start

1. `Command-Shift-4` starts exactly one selection session.
2. Repeated triggers during an active session are ignored.
3. Selection mode appears immediately enough that the user can press the hotkey
   and start dragging without waiting.
4. Before the user starts dragging, QuickShot does not show a dark overlay,
   loading veil, frozen desktop image, spinner, or progress layer.
5. QuickShot's own windows, hub, thumbnails, settings, and helper UI must not be
   visible inside the final screenshot.
6. QuickShot must not hide and re-show the screenshot tray to keep it out of the
   final image; capture filtering must exclude QuickShot without a visible tray
   flicker.

## Before Drag

1. The screen stays visually normal.
2. The only visible selection affordance is the custom QuickShot cursor.
3. The system pointer is hidden; the user must not see two cursors.
4. No selection frame or overlay is drawn until the drag starts.

## Drag Selection

1. Mouse-down starts the selection immediately.
2. The selection frame follows the pointer without lag or jumps.
3. The overlay is inverted from the previous model: it appears inside the
   selected rectangle, not outside it.
4. The outside area remains undimmed and live-looking.
5. The inner overlay is light, restrained, and content-preserving. It must not
   obscure the user's ability to inspect what is being selected.
6. The overlay exists only while there is an active selection rectangle.
7. Tiny selections below the minimum useful size are ignored on release.

## Cursor And Frame

1. The visible cursor is QuickShot's vector crosshair.
2. The cursor does not change size, anchor, or shape during drag.
3. The frame and cursor are one design system: same stroke widths, same
   halo/core contrast, round caps, and a deliberate separator where they meet.
4. There is no dot, handle, bridge, duplicate pointer, or flicker.
5. The frame remains stable for all drag directions and small selections.

## Completion

1. Mouse-up finalizes the selected region.
2. Any unavoidable capture or encoding delay happens after mouse-up.
3. A successful selection creates exactly one new thumbnail and copies the image
   to the clipboard.
4. The screenshot must correspond to the completed selection and must not reuse
   an old screenshot from a previous attempt.
5. If a fresh result cannot be produced, QuickShot restores the UI and reports
   failure instead of showing stale pixels.
6. `Esc` cancels selection and restores all cursor/window state.

## Tray And Hub

1. Hub click toggles thumbnail collapse/expand.
2. A new screenshot expands the tray.
3. Hub action buttons are clickable and do not accidentally toggle collapse.
4. Per-thumbnail `Copy`, close, resize, and card interactions remain clickable.
5. The tray/hub position is based on full screen frames and may overlap Dock or
   menu bar.
6. The hub is a compact Vercel/Geist-inspired command surface.
7. Hover reveal exposes three visible actions: `Delete`, `Save`, and `Copy`.
8. Per-thumbnail controls use QuickShot's custom command-button chrome, not
   native Liquid Glass buttons.
9. Empty transparent tray space does not steal pointer events from controls.
10. The tray must not blink during capture completion.

## Interface Model

1. UI architecture changes must improve interaction consistency, state
   ownership, and testability, not only visual styling.
2. QuickShot may evaluate Native SDK (`vercel-labs/native`) as an interface
   model candidate for the shell, hub, cards, command pills, focus, hover, and
   automation story.
3. A framework spike must not weaken the capture contract: immediate selection
   entry, fresh final pixels, capture exclusion, no tray blink, no stale
   screenshots, and no duplicate cursor remain mandatory.
4. Native SDK must be treated as a candidate shell/component architecture, not
   as a replacement for macOS-specific capture responsibilities until the bridge
   is proven.

## Regression Gates

1. Tests must cover immediate selection entry, cursor exclusivity, frame/cursor
   geometry, inner-overlay behavior, tray clickability, hub action clickability,
   thumbnail close clicks, and stale-result rejection.
2. Verification must include zero, one, and multiple existing screenshots in the
   tray.
3. Runtime verification on the user's active machine should prefer log-only
   checks unless synthetic input is explicitly enabled.
