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
2. Manual collapse state and hover presentation are separate. Hovering the hub
   temporarily reveals a collapsed tray without changing what the next hub
   click means.
3. Hub and visible card containers form one hover session. Moving from the hub
   or its command row onto any card keeps both the command row and cards open.
4. Leaving the complete region starts a `180ms` grace period. Re-entry cancels
   that exact pending close; superseded timers cannot close a newer session.
5. A new screenshot does not permanently expand a collapsed tray. Its
   acknowledgement uses `150ms` insertion, `1.2s` fully visible hold, and
   `130ms` exit. Hover holds it until pointer exit plus the normal grace period.
6. Hub action buttons are clickable and do not accidentally toggle collapse.
7. Per-thumbnail `Copy`, close, resize, and card interactions remain clickable.
8. Thumbnail geometry is append-only: adding a screenshot never changes any
   existing card origin. The new screenshot takes the next free slot away from
   the hub (above the stack for the current bottom-anchored vertical layout;
   below it when that anchor direction is mirrored).
9. The tray/hub position is based on full screen frames and may overlap Dock or
   menu bar.
10. The hub is a compact Vercel/Native-inspired icon+label command surface
   aligned to the House small-control register: 28pt height, 8pt radius, 14pt
   labels, 16pt icons, and 8pt gaps between independent command buttons.
11. Hover reveal exposes three visible actions: `Delete`, `Save As`, and `Copy All`.
12. Per-thumbnail controls use independent House command buttons in a
   token-spaced row, not exclusive-choice `button-group` chrome or
   native Liquid Glass buttons.
13. Empty transparent tray space does not steal pointer events from controls.
14. The tray must not blink during capture completion.
15. The left-to-right action order is always `Delete`, `Save As`, `Copy All`,
    regardless of the screen edge.
16. Hover reveal uses the House fast-motion token (`120ms`, or `0ms` under
    Reduce Motion), scales interrupted transitions by the remaining distance,
    changes width through the final frame, and does not rerender Native SDK
    pixels on every display-link tick.
17. At rest only the compact command button is visible. Hover fades in one
    token-owned House Dark bubble behind the complete command row; gaps inside
    the hub belong to that surface and pixels outside it remain transparent.
18. Bubble and button corners are concentric: House `xl` outer radius `14pt`,
    House control radius `8pt`, and their difference is the `6pt` inset.
19. Repeated `mouseMoved` events for an unchanged hover target never restart
    the active reveal animation.
20. While hover is active, cursor exit is evaluated against the stable fully
    expanded footprint independently of the resizing view. Leaving it always
    drives the bubble opacity back to zero, even if AppKit already stopped
    delivering events to the current view bounds.
21. Tray cards, chevron rotation, opacity, and shadows derive from one
    interruptible tray progress. Collection insertion/removal/reflow and the
    clipped vertical count odometer have explicit headless regression tests.

## UI Architecture

1. UI architecture changes must improve interaction consistency, state
   ownership, and testability, not only visual styling.
2. A new UI framework or shell model must not weaken the capture contract:
   immediate selection entry, fresh final pixels, capture exclusion, no tray
   blink, no stale screenshots, and no duplicate cursor remain mandatory.
3. Screenshot capture, global hotkeys, overlay windows, cursor ownership,
   capture exclusion, and clipboard writes are product-critical system
   integrations. They cannot be treated as replaceable styling details.
4. Every visible command control on hub, thumbnail, pinned, settings, and
   status-menu surfaces uses an official Native SDK primitive. Local AppKit
   control replicas and SDK-owned color/radius/state overrides are prohibited.
5. AppKit owns window hosting, the system status item, traffic-light controls,
   image presentation, and resize/drag integration. Native SDK owns command
   geometry, tokens, hover, pressed state, hit testing, and typed dispatch.
6. Swift reads control and motion metrics from the pinned House Dark token pack and
   fitting geometry from runtime semantics. It must not maintain approximate
   duplicate widths or unexplained padding reserves.
7. The visual scheme is fixed to House Dark. High Contrast and Reduce Motion
   changes are forwarded from macOS into the embedded Native SDK runtime and
   must repaint the complete surface in one transition.
8. Production and the default headless regression suite link a `ReleaseFast`
   Native UI library so timing gates exercise the shipped renderer path. Debug
   is reserved for explicit diagnostics.
9. Native SDK `button-group` is reserved for model-owned exclusive choices.
   Independent commands use a `row`; House `button-group` provides the attached
   segmented treatment only for exclusive selection.

## Regression Gates

1. Tests must cover immediate selection entry, cursor exclusivity, frame/cursor
   geometry, inner-overlay behavior, tray clickability, hub action clickability,
   thumbnail close clicks, and stale-result rejection.
2. Verification must include zero, one, and multiple existing screenshots in the
   tray.
3. Runtime verification on the user's active machine should prefer log-only
   checks unless synthetic input is explicitly enabled.
4. Headless component tests must cover actual runtime semantics, bounds,
   non-overlap, hover ownership, click dispatch, complete theme repaint, reveal
   ordering, reveal duration, render count, and first-frame budget.
5. Live-window click tests remain opt-in through
   `QUICKSHOT_RUN_LIVE_UI_TESTS=1`; the default suite must not take over the
   user's screen.
