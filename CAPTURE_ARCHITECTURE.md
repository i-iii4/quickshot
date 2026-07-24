# QuickShot Capture Architecture

Status: remediation implemented; automated release gates pass locally and in
CI. The manual runtime and latency gate remains pending for the exact release
build.

Audited baseline: `d54b267`.

The 24 July audit found three release-blocking correctness defects, several
unbounded resource and ordering risks, and test/build gaps that allowed those
defects to remain green. Phases 1-5 and the automated part of Phase 6 are now
implemented. This document preserves the findings, the resulting architecture,
and the remaining release gates.

## Remediation Result

- `CaptureGestureBuffer` retains a complete early down/drag/up gesture, while a
  session-owned Carbon Escape registration remains active through teardown.
- `CaptureSequence`, `CaptureDeliveryState`, and `CaptureArtifactStore` own
  chronology, clipboard freshness, one-time encoding, file leases, cleanup, and
  the 100-card/1-GiB resource bound.
- `ScreenSnapshotProviding` isolates the fakeable provider boundary. Production
  captures fresh pixels through one serialized direct lane, rejects incomplete
  or over-skewed display batches, and performs no pixel-producing prewarm.
- Window exclusion audits fail closed. The accepted multi-display contract is
  serialized full-resolution display capture with a measured maximum batch skew
  of `120ms`; a batch outside that bound fails instead of pretending to be
  atomic.
- `ThumbnailCollectionModel` owns order, viewport, and follow-newest state.
  Geometry is clamped per display, and pointer routing is refreshed after every
  state and animation commit.
- Production and tests compile in Swift 6 with complete strict concurrency and
  warnings as errors.
- Native UI Design System `0.1.0` is resolved from one configured input and
  locked to `b2e7cb0ad13a05d39dfc8e6ded91ab86817b9869`; the Zig manifest no longer
  assumes a sibling `node_modules` path.
- Production builds compile, sign, and verify a staging bundle. `renameatx_np`
  swaps it with the installed app atomically; compiler, signing, and pre-install
  failure tests prove that the previous valid app remains unchanged.
- The default headless suite includes 100 randomized delivery lifecycles, 100
  fake-backend lifecycles, and a 100-artifact resource and cleanup stress test.
- GitHub Actions run `30113252125` passed the complete clean-runner matrix on
  `macos-26`: pinned dependency resolution, headless tests, production
  build/signature, and failed-build preservation.

The remaining release evidence is intentionally manual: cursor appearance,
fullscreen Spaces, source hover preservation, physical display combinations,
and measured p50/p95 latency. These checks post real input or present capture UI
and therefore remain opt-in on the user's active machine.

## Product Decision

QuickShot keeps the freeze-first user experience:

```text
hotkey
  -> fresh pixels before QuickShot activation
  -> immutable frozen backdrop
  -> one custom cursor and selection frame
  -> crop the same frozen image on mouse-up
  -> thumbnail and clipboard delivery
```

The following product properties remain non-negotiable:

- pixels preserve the source hover, tooltip, menu, and active appearance;
- the selector never uses a cached frame or a second mouse-up capture;
- exactly one custom cursor is visible;
- QuickShot UI is excluded without blinking or moving;
- an early drag is accepted instead of discarded;
- repeated captures remain ordered and never expose an older result as newest;
- failure, cancellation, and shutdown restore cursor, windows, input, and focus.

The direct CoreGraphics adapter remains the production baseline during
remediation. It is isolated because the current macOS SDK marks its underlying
symbol obsolete. No replacement may enter production unless it independently
passes the complete freshness, latency, cursor, fullscreen, and multi-display
contract. There is no silent fallback to a stale stream or system subprocess.

## Current Boundaries

- `CaptureController` admits captures and owns active and finishing sessions.
- `CaptureSession` captures frozen displays, presents selection, crops, and
  initiates delivery.
- `DirectScreenSnapshotProvider` owns the direct WindowServer snapshot adapter.
- `OverlayController`, `SelectionPresentationCoordinator`, and `CursorLease`
  own selection windows, foreground acquisition, and cursor replacement.
- `WindowCaptureProtection` applies and audits `sharingType = .none`.
- `ThumbnailManager` owns card order, viewport state, hover, and tray routing.
- `Clipboard` prepares pasteboard data and temporary file URLs.
- `NativeQuickShotUI` renders Native SDK command surfaces.

These boundaries are retained where possible. The remediation introduces explicit
ownership and sequencing inside them rather than another wholesale capture
rewrite.

## Historical Audit Findings

### Release Blockers

1. A complete mouse-down/drag/mouse-up gesture can finish before the frozen
   backdrop is ready. `PreOverlayMouseTracker` then returns no seed because the
   button is no longer held, and the user's selection is lost.
2. Every card prepares a clipboard payload while automatic clipboard delivery
   prepares another. Temporary PNG files have no owner or cleanup policy, and
   decoded images plus PNG/TIFF payloads grow without a resource budget.
3. Finishing sessions run concurrently without a monotonic delivery contract.
   An older crop or encode can finish after a newer capture, insert out of order,
   or overwrite the clipboard with the older image.

### High-Risk Gaps

- `Esc` before overlay construction relies on a global key monitor that is not
  reliable without Accessibility permission.
- startup preparation and a user capture share one non-preemptible direct
  capture lane;
- per-display snapshots are serialized, so exact cross-display simultaneity is
  not currently proven;
- a failed WindowServer protection audit returns `nil` and capture proceeds;
- tray follow-newest behavior contradicts the absolute append-only wording;
- card width is not clamped to the current display's available geometry;
- fullscreen host pointer routing can become stale after layout/removal until
  the next pointer event;
- AppKit isolation is conventional rather than compiler-enforced;
- source-scanning tests verify tokens in files instead of complete lifecycle
  behavior;
- the Native UI dependency is an unpinned sibling path;
- the build deletes the previous app before a new artifact is valid and ignores
  an ad-hoc signing failure.

## Target Ownership Model

### Capture Request

Every accepted hotkey receives a monotonic `CaptureSequence` and one immutable
request record:

```text
CaptureRequest
  sequence
  sessionID
  hotkeyTimestamp
  pointerLocation
  displaySet
  gestureBuffer
```

The sequence is the source of truth for thumbnail order and clipboard freshness.
UUIDs continue to identify ownership, but UUID order is never used as chronology.

### Selection Lifecycle

The main-actor admission state is:

```text
idle
  -> snapshotting(request)
  -> waitingForPresentation(request, snapshot)
  -> selecting(request, snapshot)
  -> released
  -> idle
```

Mouse-up releases admission immediately so the next capture can begin. Crop and
delivery continue as sequence-owned work outside the selection state. Every
terminal transition is idempotent.

### Gesture Buffer

A session-scoped gesture buffer starts at hotkey acceptance and records:

- first mouse-down position and timestamp;
- latest drag position;
- mouse-up position and timestamp;
- cancellation;
- the display containing the gesture.

When frozen pixels become ready:

- no mouse-down means normal selector presentation;
- a held mouse-down seeds the visible selection at the original position;
- a completed valid gesture crops immediately from the frozen snapshot;
- a completed tiny gesture follows the normal ignored-selection contract;
- `Esc` invalidates the buffer and all later mouse events are ignored.

The completed gesture is never inferred only from current button state.

### Delivery Coordinator

Crop tasks may execute outside the main actor, but all observable commits pass
through one sequence-aware coordinator:

- cards are stored and rendered in `CaptureSequence` order;
- failed/cancelled sequences release any pending ordering barrier;
- automatic clipboard work carries its sequence;
- a completion may update the clipboard only if no newer accepted capture owns
  clipboard intent;
- shutdown invalidates every uncommitted generation;
- stale callbacks cannot mutate tray or clipboard state.

### Capture Artifact Store

One `CaptureArtifact` owns all representations of one screenshot:

- the final crop produced from the immutable snapshot;
- one display-sized thumbnail;
- one encoded original payload;
- at most one temporary file URL;
- active pasteboard/drag leases;
- cleanup state.

Encoding is performed once and reused by automatic copy, per-card copy, drag,
save, pin, and Copy All. A clipboard temporary PNG is a post-crop delivery
representation; it is never a pixel source for the screenshot.

Cleanup rules:

- superseded pasteboard files are removed after their pasteboard lease ends;
- card removal releases card-owned artifacts;
- active drag leases keep their file alive until drag completion;
- shutdown removes every unleased artifact;
- startup removes stale QuickShot artifacts left by a crash;
- hidden cards do not retain full decoded images when a thumbnail and encoded
  original are sufficient.

The implementation must define and enforce a session resource budget. The first
target is 100 cards or 1 GiB of owned artifacts, whichever is reached first.
QuickShot must reject a new capture with visible feedback rather than silently
delete user data or continue unbounded.

### Snapshot Provider

`DirectScreenSnapshotProvider` remains behind a protocol so tests can provide
deterministic snapshots and delays.

The production adapter must:

- resolve backend availability without taking a preparatory screenshot;
- give user capture priority over all background preparation;
- never cache pixels between sessions;
- report one capture timestamp per display and the maximum batch skew;
- reject incomplete or mismatched display sets;
- discard cancelled results even when the synchronous OS call returns later;
- expose structured latency and failure metrics.

Exact multi-display simultaneity is an explicit architecture decision gate. The
current serialized per-display backend cannot truthfully guarantee one identical
timestamp. Before release, one of these outcomes must be selected and documented:

1. an atomic full-resolution batch passes mixed-DPI pixel-fidelity tests; or
2. selection is contractually limited to the hotkey display; or
3. the product explicitly accepts and bounds measured per-display skew.

The documentation must not claim exact all-display hotkey simultaneity until
this gate is closed.

### Window And Pointer Ownership

Window capture protection is fail-closed:

- every QuickShot window is protected at creation;
- the registry is reapplied before every snapshot;
- an unavailable WindowServer audit is a capture failure;
- any visible unprotected QuickShot surface is a capture failure;
- failure presents no selector and never hides the tray as a workaround.

The tray host remains mouse-transparent by default. Pointer ownership is
recomputed after every layout, insertion, removal, collapse, viewport move,
animation completion, capture transition, screen change, and pointer event.
Changing routing during a mouse-down must not consume the user's first click.

### Tray Model

Card identity and order live in a model independent of views. The resolved tray
contract is:

- while a free visible slot exists, a new card occupies that slot and no existing
  card changes origin;
- once the viewport is full, it advances deterministically toward the newest
  card;
- overflow cards remain ordered and scroll-reachable;
- no hidden card is mounted at a default or stale coordinate;
- resizing is clamped to the current display and recomputed after display changes.

### Concurrency Model

- all AppKit windows, views, controllers, and callbacks are `@MainActor`;
- snapshot and encoding data crossing actors is explicitly `Sendable`;
- artifact I/O is owned by an actor;
- direct capture serialization is owned by an actor or equivalent typed boundary;
- Carbon callbacks perform the minimum C bridge and dispatch to the main actor;
- no concurrency warning is suppressed to make the build green.

The target compiler gate is Swift 6 with complete strict concurrency and zero
warnings.

## Remediation Program

Each phase lands as a separate reviewable commit. A phase cannot start until the
previous phase's exit criteria are green.

### Phase 0 - Freeze The Baseline

Scope:

- preserve `d54b267` as the audited behavior baseline;
- add deterministic fakes for snapshot, clock, event input, clipboard, and
  artifact storage;
- convert each P0 finding into a failing behavioral test;
- keep all runtime UI automation opt-in.

Exit criteria:

- tests reproduce completed early-drag loss, stale clipboard completion, and
  artifact leakage before production behavior changes;
- the default suite remains headless;
- no source-string assertion is accepted as the sole proof of a lifecycle rule.

### Phase 1 - Repair Input And Session Lifecycle (Complete)

Scope:

- replace `PreOverlayMouseTracker` with the typed gesture buffer;
- register session-scoped Carbon Escape immediately at capture acceptance;
- replay held and completed gestures from stored coordinates;
- make cancel/failure/shutdown invalidate all pending callbacks;
- centralize selection state transitions on `@MainActor`.

Required tests:

- down/drag/up completes before snapshot readiness;
- mouse remains held when presentation becomes ready;
- Escape during snapshot, activation wait, selection, and delivery;
- snapshot completion after cancellation is ignored;
- duplicate finish/cancel calls are idempotent;
- activation rejection/loss restores input and focus exactly once.

Exit criteria:

- no accepted gesture is lost;
- exactly one cursor lease exists;
- every terminal path leaves zero overlay windows and a balanced cursor.

### Phase 2 - Order Delivery And Bound Resources (Complete)

Scope:

- introduce `CaptureSequence` and the delivery coordinator;
- replace repeated `Clipboard.prepareImage` calls with one artifact;
- add pasteboard and drag leases;
- clean superseded, removed, shutdown, and crash-leftover files;
- release full decoded images after thumbnail/artifact preparation;
- enforce the resource budget without silent eviction.

Required tests:

- older crop finishes after newer crop;
- older encode finishes after newer encode;
- newer capture remains the clipboard result;
- card order follows capture order;
- copy, drag, pin, save, and Copy All reuse the same artifact;
- delete one, Delete All, pasteboard replacement, shutdown, and startup cleanup;
- 100 sequential captures produce bounded memory and no unleased temp files.

Exit criteria:

- one encode and at most one temporary file per screenshot;
- zero stale callbacks after shutdown;
- repeated captures cannot reorder the tray or clipboard;
- resource use reaches a stable bound during the stress test.

### Phase 3 - Harden Snapshot And Protection (Complete)

Scope:

- remove pixel-producing prewarm work;
- separate backend availability/permission checks from screen capture;
- give accepted user requests exclusive capture priority;
- make protection audit failures fail-closed;
- record display timestamps, batch skew, and stage latency;
- close the multi-display decision gate;
- retain an explicit unsupported-backend error when the direct symbol is absent.

Required tests:

- user capture cannot queue behind preparation;
- cancellation while the OS call is running discards its result;
- missing, duplicate, and mismatched displays fail;
- `nil` protection audit and an unprotected window fail before snapshot;
- mixed-scale, negative-origin, and reordered displays;
- backend-unavailable startup and runtime behavior.

Exit criteria:

- no background task can delay an accepted capture;
- QuickShot never captures while its exclusion state is unknown;
- the multi-display contract states and tests one truthful behavior.

### Phase 4 - Make Tray State Deterministic (Complete)

Scope:

- move card ordering and viewport state into a pure model;
- implement the clarified free-slot and overflow behavior;
- clamp width and layout to every current screen geometry;
- refresh pointer routing after every state and geometry commit;
- make animations projections of model state rather than owners of state.

Required tests:

- zero, one, and many cards on every tray edge;
- insertion before and after viewport capacity;
- scrolling away from and back to newest;
- removal of visible and hidden cards;
- interrupted insertion/removal/collapse animations;
- small displays, mixed displays, negative origins, and persisted maximum width;
- first click after card removal or tray movement reaches the underlying app.

Exit criteria:

- no card appears outside a valid slot;
- overflow is deterministic and newest is discoverable;
- empty host pixels never consume a click;
- animation completion cannot resurrect hidden views.

### Phase 5 - Enforce Concurrency And Reproducible Builds (Complete)

Scope:

- annotate AppKit ownership with `@MainActor`;
- make cross-actor payloads explicitly safe;
- compile production and tests in Swift 6 strict concurrency;
- replace the hard-coded sibling Native SDK path with one resolved dependency
  input;
- pin the Native UI design-system revision in a lock file;
- build into a temporary bundle, sign and verify it, then atomically replace the
  previous app;
- make every signing failure fatal;
- add macOS CI for headless tests, strict compilation, Native SDK validation,
  production build, and signature structure.

The initial dependency lock should record the currently audited design-system
revision `b2e7cb0`; later updates require an explicit lock change and full suite.

Required gates:

- zero strict-concurrency warnings;
- clean checkout builds without an implicit sibling `node_modules` layout;
- a forced compiler/signing failure leaves the previous app untouched;
- CI runs on every pushed commit.

### Phase 6 - Release Verification (Automated Complete, Manual Pending)

Automated:

- complete headless suite;
- strict-concurrency gate;
- artifact and memory stress test;
- 100 fake-backend lifecycle repetitions with randomized completion order;
- Native SDK dispatch and render gates;
- production build and signature verification.

Manual runtime gate:

- ten sequential captures with zero stale, missing, or reordered cards;
- normal windows and fullscreen Spaces;
- source hover, tooltip, menu, and active-state preservation;
- immediate drag and a completed drag before selector reveal;
- Escape during every capture phase;
- one cursor before, during, and after drag;
- desktop input immediately after success, cancel, and failure;
- one, many, collapsed, expanded, and overflowed tray states;
- mixed-scale displays and negative origins;
- Dock/menu-bar overlap on every tray edge.

Performance:

- collect at least 50 hotkey-to-selector and mouse-up-to-card samples;
- report p50, p95, and maximum rather than a single successful run;
- `hotkey-to-selector <= 120ms p95`;
- `mouse-up-to-card <= 100ms p95`;
- no multi-second outlier is waived without a documented product decision.

Runtime checks that post input remain opt-in and must not take over the user's
screen during ordinary development or CI.

## Definition Of Done

QuickShot is release-ready only when all of the following are true:

- all Phase 0-6 gates pass from a clean checkout;
- a completed early gesture always produces its intended crop;
- Escape works from hotkey acceptance through selector teardown;
- every successful capture has fresh session-owned pixels;
- exactly one custom cursor is visible and cursor balance returns to zero;
- no QuickShot surface appears in frozen or delivered pixels;
- cards and automatic clipboard delivery obey capture sequence;
- one screenshot owns one reusable delivery artifact;
- no unleased QuickShot temporary file survives cleanup;
- the 100-capture stress test remains within the declared resource budget;
- protection failure is fail-closed;
- tray free-slot, overflow, scrolling, and pointer pass-through contracts pass;
- Swift 6 strict concurrency produces zero warnings;
- Native UI dependency resolution is pinned and reproducible;
- a failed build cannot destroy the last valid app;
- CI is green;
- the manual runtime and latency gates are recorded for the exact release build.

Passing the current tests or producing a signed app is necessary but no longer
sufficient evidence of completion.
