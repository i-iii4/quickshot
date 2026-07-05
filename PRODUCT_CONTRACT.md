# QuickShot Product Contract

This document is the product contract for the screenshot capture flow. Any
implementation that violates these rules is considered a regression, even if it
passes compilation.

## Capture Flow

1. `Command-Shift-4` starts exactly one capture session. Repeated triggers during
   an active session are ignored.
2. The visible selection overlay must become interactive immediately after the
   hotkey. For the global shortcut, `capture overlay ready` is measured from
   the Carbon `hotkey event received` timestamp, not from a later internal
   callback. The target budget for hotkey-to-overlay-ready is below 100 ms; a
   2-3 second overlay delay is a product failure.
3. Frozen pixels are installed separately from overlay activation. A pending
   backdrop is acceptable only while QuickShot waits for a fresh stream-cache
   frame; a stale cached frame must never be shown as the frozen backdrop or
   used for the final crop.
4. If the user presses the hotkey and immediately starts dragging, QuickShot must
   preserve the gesture intent. The user must not have to release the mouse and
   start again.
5. The final cropped image must always come from the fresh frozen frame
   installed for this capture request. If the user finishes selection before
   that frame arrives, the selection is stored and completed only after the
   fresh frame is available.
6. QuickShot UI must never appear in the frozen frame or final screenshot:
   selection overlay, custom cursor, selection frame, hub, thumbnails, settings,
   or menu-bar helper windows are all excluded by hiding them before capture or
   by a proven ScreenCaptureKit exclusion filter.
7. Normal warm capture should feel immediate. `capture overlay ready` measures
   the interactive overlay, not the frozen backdrop. Frozen-frame readiness must
   be logged separately as `capture frozen ready`.
8. Releasing a valid selection must not keep the selection overlay on screen
   while QuickShot encodes PNG/TIFF data, writes the temporary fileURL payload,
   or lays out screenshot cards. It also must not crop the frozen `CGImage`
   synchronously inside the mouse-up handler. The session dismisses the overlay,
   restores hidden windows, logs `capture end outcome=completed`, and only then
   schedules background crop plus thumbnail/clipboard delivery. Delivery itself
   must emit an explicit `capture delivery outcome=completed|crop-failed|handoff-failed`
   result so session completion is not confused with image publication. Clipboard payload
   preparation must run off the main mouse-up path and publish only the prepared
   payload back to `NSPasteboard`. The same prepared payload model applies to
   thumbnail copy, copy-all, pinned-window copy, and drag-out: production controls
   must not rebuild PNG/TIFF data with AppKit image reps inside click or drag
   handlers.
9. The hotkey path must use the ScreenCaptureKit stream cache. It must not call
   one-shot `SCScreenshotManager` capture from `CaptureController` or rebuild
   `SCShareableContent` on the main/UI activation path. If a hotkey arrives
   during startup warmup, the overlay still appears first and fresh-frame
   resolution continues off-main.
10. A cached ScreenCaptureKit stream frame is acceptable for active capture only
   if its pixels were produced after the current capture request
   (`updatedAt >= requestedAt`). QuickShot may still track `validatedAt` for
   maintenance and stream-health decisions, but validation must not authorize a
   pre-request pixel buffer as the frozen backdrop or final crop. Every accepted
   stream frame must log its acceptance source as `post-request`; `responsive`
   and `validated` acceptance sources are forbidden for active capture.
   If ScreenCaptureKit returns no displays after the supported shareable-content
   recovery attempts, `ScreenFrameCache` may use a cache-owned rect snapshot
   recovery through `SCScreenshotManager.captureScreenshot(rect:)`. This is only
   allowed if QuickShot windows opt out of WindowServer capture via
   `NSWindow.sharingType = .none`; `CaptureController` must still not own a
   screenshot API fallback. Because rect snapshot recovery runs on the active
   capture path, it must have a short direct-manipulation timeout and a recent
   failure cooldown; a broken system capture stack must not be re-probed for
   multiple seconds on every repeated mouse-up. Empty shareable-content display
   listings must also have a short health cooldown so active capture does not
   repeatedly run the whole `SCShareableContent` recovery chain right after
   prewarm proved `displays` is empty. Empty listings should schedule a tiny
   background rect-snapshot health probe so QuickShot can mark the screenshot
   stack unhealthy before the next active selection needs fallback. If active capture arrives while that health probe is
   still in flight, it may join only a very short probe budget and must not start
   a duplicate `SCScreenshotManager` fallback in parallel. If rect snapshot
   recovery also fails, the capture session must fail immediately with typed
   `captureStackUnavailable`, an explicit log, and a nonmodal one-shot attention
   request instead of masking the system failure as `noDisplay`, waiting for the
   full frozen-frame timeout, or showing repeated blocking alerts.
   `ScreenFrameCache.start` must return a typed start result with the cache-owned
   unavailable reason; `CaptureSession` must pass that reason through recovery
   and failure instead of reconstructing cache internals from a bare Boolean.
   The same typed failure boundary applies if an active stream cache starts but
   no fresh frozen frame is available before the bounded wait expires.
11. After any capture session ends, QuickShot must start preparing the target
    display for the next capture in the background. Recovery from a stale stream
    must be paid in the post-capture idle path whenever possible, not deferred
    until the next user gesture. This idle preparation must not immediately tear
    down/restart the active stream or start screenshot/prepared-image work; it
    may only request or validate a fresh live stream frame. Stream restarts
    remain reserved for the active capture recovery path or slower maintenance.
    If an active capture recovery request arrives while an idle refresh is still
    in flight, the active request must supersede the idle owner; stale idle tasks
    must not clear or block newer higher-priority refresh work.
    Separately, age maintenance must request a fresh live stream frame before
    cached pixels become suspect; destructive background stream restart is
    reserved for much older suspect streams.
12. A prepared frozen image, when produced by capture-time fallback, is stricter
    than a live stream frame: it may be served only when it was produced after
    the current capture request. Its longer retention window is only for cleanup,
    not permission to serve an older screen state, and it must be purged after
    the retention window expires.
13. Post-capture preparation must be stream-only. It may request or validate a
    live `SCStream` frame, but it must not start `SCScreenshotManager` work or
    create a joinable prepared task that the next mouse-up can wait on. If the
    user completes selection before the frozen frame is ready, the overlay must
    dismiss immediately after recording the selection, while the session keeps
    QuickShot windows hidden and finishes crop when the frozen frame arrives.
    Capture-time screenshot fallback must start only after the stream refresh
    grace and must have its own timeout.
    Background refresh priority must match user intent: active capture recovery
    may run as user-initiated work, while maintenance and post-capture idle
    refresh must run as utility work so they do not compete with crop/delivery.
14. Stream startup/restart coordination is display-scoped. Recovery or startup
    for one display must not silently block an unrelated display from starting
    its own stream. A display that is merely in `startingDisplays` is not yet a
    usable cache source: active capture may wait only a short bounded stream
    registration window before proceeding to recovery/failure instead of waiting
    the full frozen-frame deadline on someone else's startup.
15. Resolving a `CVPixelBuffer` into the frozen `CGImage` must not happen
    synchronously on the main actor before the overlay has had a chance to paint.
    The UI road is hotkey -> live overlay -> hide QuickShot windows before
    frozen-frame work. Frame conversion, stream refresh, and any stream-owned
    snapshot happen in the background and return to the main actor only to
    install the finished image.
16. The frozen-frame wait deadline is a background capture deadline, not an
    overlay deadline. It must be a named direct-manipulation budget: long enough
    to let the warmed stream or short recovery finish, but not a multi-second
    parking lot for a broken ScreenCaptureKit stack. It must never keep the
    overlay from becoming interactive.
17. Once screen-recording permission has been confirmed, normal hotkey capture
    must not perform a fresh TCC/preflight check before overlay activation.
    Permission checks on the hot path are allowed only while access is unknown
    or previously denied. A previously granted permission may be remembered
    optimistically across launches, while a background prewarm preflight refreshes
    the actual state.
18. Overlay construction must not force a synchronous full-screen render before
    the window is ordered front. The hot path creates views and orders windows;
    AppKit can render the lightweight chrome naturally on the next paint.
19. App activation and key-window assignment are not part of the first-pixel
    overlay path. They may be scheduled immediately after overlay setup for Esc
    and key handling, but must not block `capture overlay ready`.
20. Application shutdown must be explicit. If QuickShot terminates during a
    capture, it must dismiss overlay windows, restore hidden/cursor state, cancel
    capture work and owned startup prewarm work, stop stream-cache work, and
    avoid scheduling post-capture prewarm. Already-running async cache tasks must
    not be able to recreate streams after shutdown starts, and stale prewarm
    completions must not update permission state after a newer prewarm or
    shutdown invalidates them.

## Overlay

1. There is one overlay window per screen, matching the exact `NSScreen.frame`.
   The overlay must not be shifted by Dock, menu bar, or `visibleFrame`.
2. The overlay is modal to the current Space. If the active Space changes during
   selection, the capture is cancelled and all overlay/cursor state is restored.
3. Once the frozen backdrop is installed, it is static for the whole session.
   The unselected area may be dimmed, but the selected area shows the same
   frozen pixels at full contrast.
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
9. The tray host content view must route events only to interactive subviews and
   return `nil` for empty transparent space. Hub action clickability must be
   verified through the host window/content-view path, not only by calling
   `HubWindow.hitTest` directly.
10. Per-thumbnail controls (`Copy`, close `x`, resize handle, card body) must
    remain clickable through the same tray host/content-view path. A fix for hub
    click-through must not make individual screenshot controls unreachable.
11. Per-thumbnail `Copy` and close controls must use QuickShot's custom
    Vercel/Geist-like command-button chrome, not native Liquid Glass
    `NSButton .glass`. The full-size pinned window can keep separate native
    controls unless its contract is changed explicitly.

## Observability And Regression Gates

1. The capture path logs phase timings for trigger, ScreenCaptureKit content
   enumeration, per-display screenshot, overlay creation, selection completion,
   final crop, successful clipboard handoff of the cropped image, and capture
   session end with an explicit outcome.
2. Timing logs must not contain screenshot content or user text from the screen.
3. Tests must cover pure geometry and interaction contracts where possible:
   cursor/frame geometry, crop math, hub clickability, action clickability, and
   hub reveal states.
4. Tests must also cover `ScreenFrameCache` rejection of old pre-request cached
   frames and AppKit-window dispatch for hub action clicks through the tray host
   content view, plus per-thumbnail close clicks through the card container.
5. Static regression gates must forbid synchronous `frameCache.frozenScreen`
   calls from `CaptureController`; otherwise a future change can recreate the
   bug where an overlay window is constructed but the main actor is blocked
   before the user sees it.
6. Static regression gates must also verify ordering: `CaptureSession.start`
   activates `beginOverlay` before hiding QuickShot windows and before starting
   frozen-frame work, while still hiding QuickShot windows before frozen-frame
   work. No ScreenCaptureKit, screenshot, cache-wait, image-conversion,
   global-event-monitor registration, or window-hide token may appear before
   overlay activation.
7. Static regression gates must forbid `displayIfNeeded()` in `Overlay.swift`
   unless this contract is explicitly revised; forcing full-screen display before
   `orderFront` can recreate the visible multi-second overlay delay.
8. Static regression gates must verify that overlay app activation is deferred
   until after `overlay begin`, so WindowServer activation cannot block the
   first visible overlay frame.
9. Manual verification after any capture-flow change must use a freshly restarted
   `QuickShot.app` process. A successful build is not evidence that the running
   menu-bar app changed.
10. Runtime verification must enforce the same overlay timing budget on cold
   start and warm start; a cold-start verifier that allows multi-second overlay
   readiness is not a valid regression gate.
   Verifiers must distinguish controller-owned one-shot fallback from the
   allowed cache-owned rect snapshot recovery, and report the latter explicitly
   as `rectSnapshot=yes`.
11. If synthetic hotkey testing would interrupt the user, `verify-capture-observed`
    may be used after a manual capture: it must read logs only, never post input,
    and still enforce the same overlay timing, fallback, stale-frame, and
    permission-preflight invariants. With `REQUIRE_COMPLETED_SELECTION=1`, it
    must also prove frozen readiness, crop completion, clipboard handoff, overlay
    dismissal, cursor restoration, `capture end outcome=completed`, and
    post-capture preparation, while forbidding aggressive
    `post-capture prewarm` stream restart escalation.
    Any verifier that posts synthetic keyboard or mouse input must require an
    explicit opt-in flag before it builds, restarts QuickShot, or posts events.
    The default verification path must stay log-only/non-interruptive.
12. Runtime verification must include at least one completed drag-selection path,
   not only `Esc` cancellation. The completed path must prove crop completion,
   clipboard output, cursor restoration, and absence of overlay/cursor pixels in
   the final image.
13. Static regression gates must verify that screenshot delivery and tray/pinned
    controls use the centralized `Clipboard.PreparedImage` path. Production
    copy/drag handlers must not reintroduce direct `NSBitmapImageRep(cgImage:)`,
    `tiffRepresentation`, or synchronous `Clipboard.copy(cgImage:)` work.
    `Clipboard` itself must not expose synchronous `copy(cgImage:)` or
    `copyAll(cgImages:)` convenience APIs. Static gates must also forbid
    `.crop(globalSelection:)` inside `completeSelection`; completed selection may
    only schedule background crop and return control to AppKit.
14. `ScreenFrameCache` must distinguish three startup states: pending display
    startup, registered `CachedDisplayStream`, and started stream. Only a real
    frame, a retained prepared image, or a stream marked started after
    `startCapture()` may make capture startup report usable cache. A raw
    `streams[id] != nil` check must not send active capture into the long
    frozen-frame wait, because that recreates the repeated-screenshot `mouseUp`
    delay.
