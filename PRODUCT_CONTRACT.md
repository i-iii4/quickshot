# QuickShot Product Contract

This document is the product contract for the screenshot capture flow. Any
implementation that violates these rules is a regression, even if it compiles.

## Capture Flow

1. `Command-Shift-4` starts exactly one capture session. Repeated triggers during
   an active session are ignored.
2. QuickShot uses a stream-backed fresh-frame-first flow: hide QuickShot
   windows, accept a complete ScreenCaptureKit stream frame only after the
   trigger and post-hide boundary, then show the selection overlay on top of
   those immutable pixels.
3. No pre-trigger desktop pixels may become the frozen backdrop or final crop.
   Every frozen image used for a session must be accepted after that session's
   trigger and after QuickShot windows have been hidden.
4. Normal warm capture should feel near-instant. The target budget for
   hotkey-to-overlay-ready is 200 ms, with Mio's public target in the tens of
   milliseconds after prewarm. The capture path logs both `capture frozen ready`
   and `capture overlay ready`.
5. Startup prewarm starts persistent warm ScreenCaptureKit streams. It must not
   show QuickShot UI and must not block app launch.
6. Warm streams remain active while QuickShot runs. The macOS screen-capture
   indicator is an accepted product tradeoff for deterministic hot capture.
7. The stream path has a short fresh-frame deadline. It first prefers a
   post-hide complete frame or idle heartbeat; if ScreenCaptureKit withholds that
   heartbeat on a static display, it must use a fresh
   `SCScreenshotManager.captureImage` fallback rather than a stale stream
   buffer.
8. `SCShareableContent.current` and `SCScreenshotManager.captureImage` are
   allowed only in startup/background stream refresh or the explicit fresh
   one-shot fallback after stream freshness is unavailable.
9. If the user presses the hotkey and is already holding a drag when the overlay
   appears, QuickShot seeds the selection from the pre-overlay mouse state so the
   user does not have to release and start again.
10. QuickShot UI must never appear in the frozen frame or final screenshot:
   selection overlay, custom cursor, selection frame, hub, thumbnails, settings,
   and helper windows are hidden before freeze or excluded from capture with
   window sharing protection.
11. Releasing a valid selection dismisses the overlay before PNG/TIFF encoding,
   temporary file payload work, thumbnail layout, or clipboard publication. The
   session logs `capture end outcome=completed`, then schedules background crop
   and delivery.
12. Cropping the frozen `CGImage` must not happen synchronously inside the
    mouse-up handler. Crop runs off the main path and returns to the main thread
    only for logging and thumbnail/clipboard handoff.
13. Delivery emits `capture delivery outcome=completed|crop-failed|handoff-failed`
    so session completion is not confused with image publication.
14. Clipboard payload preparation must run off the UI path and publish only the
    prepared payload back to `NSPasteboard`. The same prepared payload model
    applies to thumbnail copy, copy-all, pinned-window copy, and drag-out.
15. Permission checks are not repeated on the normal hotkey path once screen
    recording access is known. A background prewarm refreshes the actual state.
16. Application shutdown is explicit: active overlay windows are dismissed,
    hidden windows and cursor state are restored, owned prewarm/freeze work is
    cancelled, and late async work cannot resurrect capture state.

## Overlay

1. There is one overlay window per screen, matching the exact `NSScreen.frame`.
   The overlay must not be shifted by Dock, menu bar, or `visibleFrame`.
2. The overlay is modal to the current Space. If the active Space changes during
   selection, the capture is cancelled and all overlay/cursor state is restored.
3. The frozen backdrop is present when the overlay is constructed and stays
   static for the whole session. The unselected area may be dimmed, but the
   selected area shows the same frozen pixels at full contrast.
4. `Esc` cancels the active session from any screen.
5. Completion dismisses every overlay window exactly once and restores all cursor
   suppression state.
6. Overlay construction must not force a synchronous full-screen render through
   `displayIfNeeded()` before the window is ordered front.

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
   clipboard through the prepared clipboard path.
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
9. The tray host content view must route events only to interactive subviews and
   return `nil` for empty transparent space.
10. Per-thumbnail controls (`Copy`, close `x`, resize handle, card body) must
    remain clickable through the tray host/content-view path.
11. Per-thumbnail `Copy` and close controls must use QuickShot's custom
    Vercel/Geist-like command-button chrome, not native Liquid Glass
    `NSButton .glass`.

## Observability And Regression Gates

1. The capture path logs phase timings for trigger, per-display freeze, frozen
   readiness, overlay creation, selection completion, final crop, clipboard
   handoff, and session end with an explicit outcome.
2. Timing logs must not contain screenshot content or user text from the screen.
3. Tests must cover cursor/frame geometry, crop math, hub clickability, action
   clickability, thumbnail close clicks, and hub reveal states.
4. Static gates must verify that the old unsafe stale-cache architecture is
   absent from active code and docs, and that `ScreenFreezePipeline` owns
   persistent ScreenCaptureKit stream work.
5. Static gates must verify ordering: `CaptureSession.start` hides QuickShot
   windows, records the post-hide freshness boundary, and starts freeze work,
   while overlay construction happens only after `capture frozen ready`.
6. Static gates must verify that the freezer uses `SCStream`, `SCStreamOutput`,
   `SCFrameStatus.complete`, `SCFrameStatus.idle`, a post-hide freshness gate, no
   idle stop, and fresh `SCScreenshotManager.captureImage` fallback. A pre-hide
   complete pixel buffer is valid only when a post-hide idle heartbeat proves the
   display did not change.
7. Runtime verification after capture-flow changes should prefer log-only checks
   unless the user explicitly opts into synthetic input. Synthetic scripts must
   keep `QUICKSHOT_ALLOW_SYNTHETIC_INPUT=1`.
8. Runtime verification must include at least one completed drag-selection path,
   not only `Esc` cancellation. The completed path must prove crop completion,
   clipboard output, cursor restoration, and absence of overlay/cursor pixels in
   the final image.
9. Performance baselines must be documented separately from the product budget.
   The 2026-07-05 one-shot baseline was approximately 590-660 ms to
   `capture overlay ready` on the warm path, with 0.6-3s one-shot probes. This
   does not relax the 200 ms contract.
10. Stream-backed performance gates should track `capture stream frame accepted`
    with its `freshness` source, `capture stream fresh frame missed`, `capture
    stream fallback to one-shot`, `capture freeze screens ready source=stream`,
    `capture freeze screens ready source=one-shot-fallback`, and `capture
    overlay ready`.
