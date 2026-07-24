import AppKit
import Darwin

@MainActor
@main
struct HubWindowBehaviorTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)

        run("core click toggles in compact state", testCoreClickTogglesCompact)
        run("core press does not recolor sliced content", testCorePressDoesNotRecolor)
        run("core remains clickable after right-edge hover expansion", testRightEdgeExpansionKeepsCoreClickable)
        run("core remains clickable after left-edge hover expansion", testLeftEdgeExpansionKeepsCoreClickable)
        run("hover expansion keeps core anchored for every tray edge", testExpansionAnchorsEveryTrayEdge)
        run("core reveals Hide and Show without screenshot wording", testCoreRevealLabels)
        run("expanded core never clips Hide or Show", testExpandedCoreLabelFits)
        run("core label fades in and Show/Hide keep one width", testCoreFadeAndStableWidth)
        run("native core states hand off without text crops", testCoreSharedElementsNeverOverlap)
        run("count odometer preserves baseline and rolls in direction", testCountOdometer)
        run("count odometer stays clipped inside the intrinsic core", testCountOdometerClipping)
        run("count odometer stays bounded during hover reveal", testCountOdometerDuringReveal)
        run("count changes keep compact shell and chevron fixed", testCountGeometryAcrossDigitWidths)
        run("chevron stays spatially fixed through hover reveal", testChevronStaysFixedThroughHover)
        run("chevron rotates continuously between tray states", testChevronRotation)
        run("visible controls stay inside shell bounds", testVisibleControlsStayInsideShellBounds)
        run("intermediate expansion frames stay contained and anchored", testIntermediateExpansionFrames)
        run("action labels are never visibly clipped", testActionLabelsAreNeverVisiblyClipped)
        run("layout metrics stay mathematically consistent", testLayoutMetricsStayConsistent)
        run("hover bubble is concentric and fades in", testHoverBubbleGeometry)
        run("action labels stay short and intentional", testActionLabelsStayShort)
        run("actions keep one visual order", testActionsKeepVisualOrder)
        run("reveal has no idle tail", testRevealHasNoIdleTail)
        run("interrupted reveal keeps a proportional deadline", testInterruptedRevealKeepsProportionalDeadline)
        run("spring retarget preserves presentation velocity", testSpringRetargetPreservesVelocity)
        run("repeated hover events do not restart reveal", testRepeatedHoverDoesNotRestartReveal)
        run("hover bubble always closes outside its footprint", testHoverBubbleClosesOutsideFootprint)
        run("tray hover session holds the hub open across card hover", testTrayHoverSessionHoldsHubOpen)
        run("reveal reuses one native render", testRevealReusesNativeRender)
        run("reveal keeps AppKit host geometry static", testRevealKeepsStaticHostGeometry)
        run("first expanded render fits one frame", testExpandedRenderFitsFrameBudget)
        run("hover is owned by Native SDK runtime", testNativeRuntimeOwnsHover)
        run("compact shell uses one stroke", testCompactShellUsesOneStroke)
        run("blank shell area is inert", testBlankShellAreaIsInert)
        run("action pill click invokes action without toggling tray", testActionClickDoesNotToggle)
        run("visible action pills click during reveal", testInteractiveActionPillsClickDuringReveal)
        run("action press survives shell mouse exit", testActionPressSurvivesShellMouseExit)
        run("every action pill is clickable in both expansion directions", testEveryActionPillIsClickable)

        print("HubWindowBehaviorTests: passed")
    }

    private static func run(_ name: String, _ test: () throws -> Void) {
        do {
            try test()
        } catch {
            fputs("HubWindowBehaviorTests: \(name) failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testCoreClickTogglesCompact() throws {
        let harness = Harness(position: .right)

        try harness.click(at: harness.hub.center)

        try require(harness.toggleCount == 1, "Expected compact core click to toggle once, got \(harness.toggleCount)")
        try require(harness.deleteCount == 0, "Core click must not trigger Delete")
    }

    private static func testCorePressDoesNotRecolor() throws {
        let harness = Harness(position: .right)
        let before = harness.hub.debugSnapshot().nativeRenderPassCount

        try harness.holdCorePress()
        let during = harness.hub.debugSnapshot().nativeRenderPassCount

        try require(during == before,
                    "Core mouseDown must not rerender independent slices into a colored pressed state")
        try harness.releaseCorePress()
        try require(harness.toggleCount == 1,
                    "Suppressing core press color must not suppress the click action")
    }

    private static func testCountOdometer() throws {
        let harness = Harness(position: .right, count: 1)
        let baseline = harness.hub.debugSnapshot().coreCountFrame
        let baselineGlobalX = harness.hub.view.frame.minX + baseline.maxX
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        harness.hub.debugTransitionCount(to: 2)
        harness.hub.setOrigin(NSPoint(x: 300, y: 40))
        harness.hub.debugSetCountTransitionProgress(0)
        let increasingStart = harness.hub.debugSnapshot().coreCountFrame
        let increasingGlobalX = harness.hub.view.frame.minX + increasingStart.maxX
        try require(abs(increasingGlobalX - baselineGlobalX) <= 1,
                    "Odometer changed right-edge alignment: baseline=\(baselineGlobalX) transition=\(increasingGlobalX)")
        if reduceMotion {
            try require(abs(increasingStart.minY - baseline.minY) <= 0.001,
                        "Reduce Motion must crossfade increasing count on its baseline")
        } else {
            try require(increasingStart.minY < baseline.minY,
                        "Increasing count must enter from below")
        }
        harness.hub.debugSetCountTransitionProgress(1)
        let increasingEnd = harness.hub.debugSnapshot().coreCountFrame
        try require(abs(increasingEnd.minY - baseline.minY) <= 0.001,
                    "Increasing count did not return to the canonical baseline")

        harness.hub.debugTransitionCount(to: 1)
        harness.hub.setOrigin(NSPoint(x: 300, y: 40))
        harness.hub.debugSetCountTransitionProgress(0)
        let decreasingStart = harness.hub.debugSnapshot().coreCountFrame
        if reduceMotion {
            try require(abs(decreasingStart.minY - baseline.minY) <= 0.001,
                        "Reduce Motion must crossfade decreasing count on its baseline")
        } else {
            try require(decreasingStart.minY > baseline.minY,
                        "Decreasing count must enter from above")
        }
        harness.hub.debugSetCountTransitionProgress(1)
        let decreasingEnd = harness.hub.debugSnapshot().coreCountFrame
        try require(abs(decreasingEnd.minY - baseline.minY) <= 0.001,
                    "Decreasing count did not return to the canonical baseline")
    }

    private static func testCountOdometerClipping() throws {
        for (oldCount, newCount) in [(1, 2), (2, 1), (9, 10), (10, 9), (99, 100)] {
            let harness = Harness(position: .right, count: oldCount)
            harness.hub.debugTransitionCount(to: newCount)
            // Production repositions the shell immediately after setting the new count.
            harness.hub.setOrigin(NSPoint(x: 300, y: 40))
            harness.hub.debugSetCountTransitionProgress(0)
            let initial = harness.hub.debugSnapshot()
            try require(initial.odometerClips,
                        "\(oldCount)->\(newCount): numeric viewport does not clip its rolling layers")
            try require(initial.odometerUsesEdgeFade,
                        "\(oldCount)->\(newCount): viewport lacks the edge fade for partial glyphs")
            try require(initial.odometerLayerCount == 2,
                        "\(oldCount)->\(newCount): odometer must own exactly incoming and outgoing layers")
            try require(initial.odometerHasOutgoingContent,
                        "\(oldCount)->\(newCount): geometry refresh discarded the old value before frame one")
            try require(initial.coreFrame.contains(initial.odometerViewportFrame),
                        "\(oldCount)->\(newCount): numeric viewport escapes the core button")
            let fixedCoreRightEdge = initial.coreFrame.maxX
            let fixedCountRightEdge = initial.odometerViewportFrame.maxX

            for progress: CGFloat in [0.1, 0.25, 0.5, 0.75, 0.9, 1] {
                harness.hub.debugSetCountTransitionProgress(progress)
                let frame = harness.hub.debugSnapshot()
                try require(frame.coreFrame.contains(frame.odometerViewportFrame),
                            "\(oldCount)->\(newCount): numeric viewport escapes the intrinsic button at \(progress)")
                try require(abs(frame.coreFrame.maxX - fixedCoreRightEdge) <= 0.001,
                            "\(oldCount)->\(newCount): intrinsic button moved its trailing edge at \(progress)")
                try require(abs(frame.odometerViewportFrame.maxX - fixedCountRightEdge) <= 0.001,
                            "\(oldCount)->\(newCount): odometer moved its trailing alignment at \(progress)")
                try require(rectsEqual(frame.coreIconFrame, initial.coreIconFrame, tolerance: 0.001),
                            "\(oldCount)->\(newCount): odometer displaced the chevron")
            }
        }
    }

    private static func testCountOdometerDuringReveal() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position, count: 9)
            harness.hub.debugTransitionCount(to: 10)
            harness.hub.setOrigin(NSPoint(x: 300, y: 40))
            harness.hub.debugSetCountTransitionProgress(0.5)
            for reveal: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                harness.hub.debugSetExpansionProgress(reveal)
                let frame = harness.hub.debugSnapshot()
                try require(frame.coreBackgroundFrame.contains(frame.odometerViewportFrame),
                            "\(position): hover reveal moved the odometer outside the core at \(reveal)")
                try require(!frame.odometerViewportFrame.intersects(frame.coreIconFrame),
                            "\(position): rolling digits overlap the chevron at reveal \(reveal)")
            }
        }
    }

    private static func testCountGeometryAcrossDigitWidths() throws {
        let harness = Harness(position: .right, count: 9)
        let singleDigit = harness.hub.debugSnapshot()
        let singleDigitShell = harness.visibleShellFrameInRoot()
        let singleDigitIcon = singleDigit.coreIconFrame.offsetBy(dx: harness.hub.view.frame.minX,
                                                                 dy: harness.hub.view.frame.minY)
        let singleDigitCount = singleDigit.coreCountFrame.offsetBy(dx: harness.hub.view.frame.minX,
                                                                   dy: harness.hub.view.frame.minY)
        let canonicalCountToChevronGap = singleDigitIcon.minX - singleDigitCount.maxX
        for count in [1, 5, 10, 99, 100] {
            harness.hub.debugTransitionCount(to: count)
            harness.hub.setOrigin(NSPoint(x: 300, y: 40))
            harness.hub.debugSetCountTransitionProgress(1)
            let changed = harness.hub.debugSnapshot()
            let changedShell = harness.visibleShellFrameInRoot()
            let changedIcon = changed.coreIconFrame.offsetBy(dx: harness.hub.view.frame.minX,
                                                             dy: harness.hub.view.frame.minY)
            let changedCount = changed.coreCountFrame.offsetBy(dx: harness.hub.view.frame.minX,
                                                               dy: harness.hub.view.frame.minY)
            try require(rectsEqual(changedShell, singleDigitShell, tolerance: 0.001),
                        "Count \(count) changed the compact shell geometry")
            try require(rectsEqual(changedIcon, singleDigitIcon, tolerance: 0.001),
                        "Count \(count) displaced the compact chevron")
            try require(abs((changedIcon.minX - changedCount.maxX) - canonicalCountToChevronGap) <= 0.001,
                        "Count \(count) changed the count-to-chevron gap")
        }
    }

    private static func testRightEdgeExpansionKeepsCoreClickable() throws {
        let harness = Harness(position: .right)
        let compactCenter = harness.hub.center
        let compactFrame = harness.visibleShellFrameInRoot()

        harness.hoverHub()

        try require(harness.visibleShellFrameInRoot().width > compactFrame.width, "Hover must expand the action shell")
        try require(pointsEqual(harness.hub.center, compactCenter),
                    "Core center moved during right-edge expansion: \(harness.hub.center) vs \(compactCenter)")

        try harness.click(at: compactCenter)

        try require(harness.toggleCount == 1, "Expanded right-edge core click should toggle once")
        try require(harness.deleteCount == 0, "Expanded core click must not trigger Delete")
    }

    private static func testLeftEdgeExpansionKeepsCoreClickable() throws {
        let harness = Harness(position: .left)
        let compactCenter = harness.hub.center
        let compactFrame = harness.visibleShellFrameInRoot()

        harness.hoverHub()

        try require(harness.visibleShellFrameInRoot().width > compactFrame.width, "Hover must expand the action shell")
        try require(pointsEqual(harness.hub.center, compactCenter),
                    "Core center moved during left-edge expansion: \(harness.hub.center) vs \(compactCenter)")

        try harness.click(at: compactCenter)

        try require(harness.toggleCount == 1, "Expanded left-edge core click should toggle once")
        try require(harness.deleteCount == 0, "Expanded core click must not trigger Delete")
    }

    private static func testActionClickDoesNotToggle() throws {
        let harness = Harness(position: .right)

        harness.hoverHub()
        let actionPoint = try harness.firstActionPoint()
        try harness.click(at: actionPoint)

        try require(harness.deleteCount == 1, "Delete action should fire once, got \(harness.deleteCount)")
        try require(harness.toggleCount == 0, "Action click must not toggle tray, got \(harness.toggleCount)")
    }

    private static func testEveryActionPillIsClickable() throws {
        for position in [TrayPosition.right, .left] {
            for title in ["Delete", "Save As", "Copy All"] {
                let harness = Harness(position: position)
                harness.hub.debugSetExpansionProgress(1)
                let point = try harness.actionPoint(title: title)

                try harness.click(at: point)

                try require(harness.toggleCount == 0,
                            "\(position) \(title): action click must not toggle tray")
                switch title {
                case "Delete":
                    try require(harness.deleteCount == 1, "\(position): Delete did not fire")
                    try require(harness.saveAsCount == 0 && harness.copyAllCount == 0,
                                "\(position): Delete fired another action")
                case "Save As":
                    try require(harness.saveAsCount == 1, "\(position): Save As did not fire")
                    try require(harness.deleteCount == 0 && harness.copyAllCount == 0,
                                "\(position): Save As fired another action")
                case "Copy All":
                    try require(harness.copyAllCount == 1, "\(position): Copy All did not fire")
                    try require(harness.deleteCount == 0 && harness.saveAsCount == 0,
                                "\(position): Copy All fired another action")
                default:
                    throw Failure("Unexpected action title \(title)")
                }
            }
        }
    }

    private static func testExpansionAnchorsEveryTrayEdge() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            let compactFrame = harness.visibleShellFrameInRoot()
            let compactCenter = harness.hub.center

            harness.hoverHub()

            let expandedFrame = harness.visibleShellFrameInRoot()
            try require(expandedFrame.width > compactFrame.width, "\(position) did not expand")
            try require(pointsEqual(harness.hub.center, compactCenter),
                        "\(position) moved core center from \(compactCenter) to \(harness.hub.center)")

            if position == .left {
                try require(expandedFrame.minX < compactFrame.minX,
                            "\(position) must reserve room left of the fixed chevron for the revealed label: \(compactFrame) -> \(expandedFrame)")
                try require(expandedFrame.maxX > compactFrame.maxX,
                            "\(position) should reveal actions to the right: \(compactFrame) -> \(expandedFrame)")
            } else {
                try require(abs(expandedFrame.maxX - compactFrame.maxX) <= 0.5,
                            "\(position) should keep shell maxX anchored: \(compactFrame) -> \(expandedFrame)")
                try require(expandedFrame.minX < compactFrame.minX,
                            "\(position) should expand to the left: \(compactFrame) -> \(expandedFrame)")
            }
        }
    }

    private static func testVisibleControlsStayInsideShellBounds() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            try harness.requireVisibleDescendantsInsideShell()

            harness.hoverHub()
            try harness.requireVisibleDescendantsInsideShell()
        }
    }

    private static func testIntermediateExpansionFrames() throws {
        let progressFrames: [CGFloat] = [0, 0.08, 0.18, 0.33, 0.55, 0.78, 1]

        for position in [TrayPosition.right, .left, .bottom, .top] {
            for count in [1, 2, 120] {
                let harness = Harness(position: position, count: count)
                let compactFrame = harness.visibleShellFrameInRoot()
                let compactCenter = harness.hub.center
                let compactRenderedCoreFrame = harness.renderedCoreFrameInRoot()

                for progress in progressFrames {
                    harness.hub.debugSetExpansionProgress(progress)
                    try harness.requireVisibleDescendantsInsideShell()
                    try require(pointsEqual(harness.hub.center, compactCenter),
                                "\(position) count \(count) moved core center at progress \(progress)")
                    let renderedCoreFrame = harness.renderedCoreFrameInRoot()
                    try require(abs(renderedCoreFrame.minY - compactRenderedCoreFrame.minY) <= 0.001 &&
                                abs(renderedCoreFrame.height - compactRenderedCoreFrame.height) <= 0.001,
                                "\(position) count \(count) moved rendered core vertically at progress \(progress): \(compactRenderedCoreFrame) -> \(renderedCoreFrame)")
                    if progress == 0 {
                        try require(rectsEqual(renderedCoreFrame, compactRenderedCoreFrame, tolerance: 0.001),
                                    "\(position) count \(count) changed compact core geometry")
                    } else {
                        try require(abs(renderedCoreFrame.maxX - compactRenderedCoreFrame.maxX) <= 0.001,
                                    "\(position) count \(count) moved the anchored core edge at progress \(progress): \(compactRenderedCoreFrame) -> \(renderedCoreFrame)")
                        try require(renderedCoreFrame.width > compactRenderedCoreFrame.width + 0.5,
                                    "\(position) count \(count) did not expand the core label")
                    }

                    let frame = harness.visibleShellFrameInRoot()
                    if position == .left {
                        try require(frame.minX <= compactFrame.minX + 0.5 && frame.maxX >= compactFrame.maxX - 0.5,
                                    "\(position) count \(count) reveal stopped containing the compact shell at progress \(progress): \(compactFrame) -> \(frame)")
                    } else {
                        try require(abs(frame.maxX - compactFrame.maxX) <= 0.5,
                                    "\(position) count \(count) maxX drifted at progress \(progress): \(compactFrame) -> \(frame)")
                    }
                }
            }
        }
    }

    private static func testActionLabelsAreNeverVisiblyClipped() throws {
        let progressFrames: [CGFloat] = [0, 0.04, 0.08, 0.14, 0.22, 0.33, 0.48, 0.64, 0.78, 0.92, 1]

        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            for progress in progressFrames {
                harness.hub.debugSetExpansionProgress(progress)
                try harness.requireVisibleLabelsAreUnclipped()
            }
        }
    }

    private static func testCoreRevealLabels() throws {
        for collapsed in [false, true] {
            for count in [1, 5, 120] {
                let harness = Harness(position: .right, count: count, collapsed: collapsed)
                let compact = harness.hub.debugSnapshot()
                let countText = count > 99 ? "99+" : "\(count)"
                try require(compact.coreTitle == countText,
                            "Compact core must show only the count, got \(compact.coreTitle)")
                try require(compact.coreHasIcon,
                            "Compact core must keep the trailing chevron")

                harness.hub.debugSetExpansionProgress(1)
                let expanded = harness.hub.debugSnapshot()
                let action = collapsed ? "Show" : "Hide"
                try require(expanded.coreTitle == "\(countText) \(action)",
                            "Expanded core label mismatch: \(expanded.coreTitle)")
                try require(!expanded.coreTitle.lowercased().contains("screenshot"),
                            "Visible core label must not contain screenshot wording")
                try require(expanded.coreFrame.width > compact.coreFrame.width,
                            "Expanded core button must grow to reveal \(action)")
            }
        }
    }

    private static func testExpandedCoreLabelFits() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            for collapsed in [false, true] {
                for count in [1, 5, 10, 100] {
                    let harness = Harness(position: position, count: count, collapsed: collapsed)
                    harness.hub.debugSetExpansionProgress(1)
                    let expanded = harness.hub.debugSnapshot()
                    try require(expanded.revealedTextUsesCompleteNativeRender,
                                "\(position) count \(count): expanded text must use the complete Native button render")
                    try require(expanded.odometerHiddenAtRest,
                                "\(position) count \(count): odometer must not replace static text")
                }
            }
        }
    }

    private static func testCoreFadeAndStableWidth() throws {
        let harness = Harness(position: .right, count: 5, collapsed: false)
        let compact = harness.hub.debugSnapshot()
        try require(compact.stableCoreContentAlpha == 1 && compact.revealedLabelAlpha == 0 &&
                    compact.compactTextUsesCompleteNativeRender,
                    "Compact state must show stable count and chevron without the action label")

        harness.hub.debugSetExpansionProgress(0.3)
        let transitioning = harness.hub.debugSnapshot()
        try require(transitioning.stableCoreContentAlpha > 0.55 && transitioning.stableCoreContentAlpha <= 1.15,
                    "Native core handoff must stay visible without a bright double exposure")
        try require(transitioning.revealedLabelAlpha > 0 && transitioning.revealedLabelAlpha < 1,
                    "Hide/Show label must fade in during expansion")

        harness.hub.debugSetExpansionProgress(0.75)
        let sharedElementHandoff = harness.hub.debugSnapshot()
        try require(sharedElementHandoff.stableCoreContentAlpha > 0.8 &&
                    sharedElementHandoff.revealedLabelAlpha > 0.8,
                    "Expanded Native core must own the late handoff")

        harness.hub.debugSetExpansionProgress(1)
        let hideWidth = harness.hub.debugSnapshot().coreFrame.width
        let showHarness = Harness(position: .right, count: 5, collapsed: true)
        showHarness.hub.debugSetExpansionProgress(1)
        let show = showHarness.hub.debugSnapshot()
        try require(abs(show.stableCoreContentAlpha - 1) <= 0.001 && show.revealedLabelAlpha >= 0.999 &&
                    show.revealedTextUsesCompleteNativeRender,
                    "Expanded state must finish the label fade: combined=\(show.stableCoreContentAlpha) revealed=\(show.revealedLabelAlpha) complete=\(show.revealedTextUsesCompleteNativeRender)")
        try require(abs(hideWidth - show.coreFrame.width) <= 0.001,
                    "Hide and Show must reserve identical core width")
    }

    private static func testCoreSharedElementsNeverOverlap() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            for count in [1, 2, 120] {
                let harness = Harness(position: position, count: count)
                for progress: CGFloat in [0, 0.18, 0.33, 0.55, 0.78, 1] {
                    harness.hub.debugSetExpansionProgress(progress)
                    let snapshot = harness.hub.debugSnapshot()
                    try require(snapshot.compactTextUsesCompleteNativeRender &&
                                snapshot.revealedTextUsesCompleteNativeRender,
                                "\(position) count \(count) progress \(progress): text fell back to a cropped render")
                    try require(snapshot.stableCoreContentAlpha > 0.55 &&
                                snapshot.stableCoreContentAlpha <= 1.15,
                                "\(position) count \(count) progress \(progress): invalid content handoff opacity \(snapshot.stableCoreContentAlpha)")
                }
            }
        }
    }

    private static func testChevronStaysFixedThroughHover() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            for collapsed in [false, true] {
                let harness = Harness(position: position, count: 5, collapsed: collapsed)
                let compactIconFrame = harness.hub.debugSnapshot().coreIconFrame
                for progress: CGFloat in [0.18, 0.33, 0.55, 0.78, 1] {
                    harness.hub.debugSetExpansionProgress(progress)
                    let frame = harness.hub.debugSnapshot().coreIconFrame
                    try require(rectsEqual(frame, compactIconFrame, tolerance: 0.001),
                                "\(position) collapsed=\(collapsed): hover moved chevron at progress \(progress): \(compactIconFrame) -> \(frame)")
                }
            }
        }
    }

    private static func testChevronRotation() throws {
        let harness = Harness(position: .right, count: 2, collapsed: false)
        let initial = harness.hub.debugSnapshot()
        let fixedIconFrame = initial.coreIconFrame
        try require(abs(initial.chevronRotation) <= 0.001,
                    "Expanded tray must begin with the baseline chevron orientation")

        harness.hub.setState(count: 2, collapsed: true)
        let transitionStart = harness.hub.debugSnapshot()
        try require(rectsEqual(transitionStart.coreIconFrame, fixedIconFrame, tolerance: 0.001),
                    "Starting chevron rotation moved its fixed host frame")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try require(abs(transitionStart.chevronRotation - .pi) <= 0.001,
                        "Reduce Motion must snap the chevron to its semantic state")
        } else {
            try require(abs(transitionStart.chevronRotation) <= 0.001,
                        "Chevron state change must not replace the icon with a jumped frame")
            try require(abs(transitionStart.chevronTargetRotation - .pi) <= 0.001,
                        "Chevron rotation target must be 180 degrees")
        }

        harness.hub.debugSetChevronProgress(0.5)
        let midpoint = harness.hub.debugSnapshot()
        try require(abs(midpoint.chevronRotation - .pi / 2) <= 0.001,
                    "Chevron must pass continuously through a 90-degree midpoint")
        try require(rectsEqual(midpoint.coreIconFrame, fixedIconFrame, tolerance: 0.001),
                    "90-degree chevron rotation moved its fixed host frame")
        try require(midpoint.chevronHostTransformIsIdentity,
                    "Chevron rotation must never transform the positioned host view")
        try require(midpoint.chevronHostClips,
                    "Chevron motion content must stay clipped to its fixed host")

        harness.hub.debugSetChevronProgress(1)
        let final = harness.hub.debugSnapshot()
        try require(abs(final.chevronRotation - .pi) <= 0.001,
                    "Collapsed tray must finish at the opposite chevron orientation")
        try require(rectsEqual(final.coreIconFrame, fixedIconFrame, tolerance: 0.001),
                    "Finished chevron rotation moved its fixed host frame")
    }

    private static func testLayoutMetricsStayConsistent() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            for count in [1, 2, 120] {
                let harness = Harness(position: position, count: count)
                harness.hub.debugSetExpansionProgress(1)
                let snapshot = harness.hub.debugSnapshot()

                try require(abs(snapshot.coreFrame.minY - snapshot.shellInset) <= 0.5,
                            "\(position) count \(count): core Y inset drifted")
                try require(abs(snapshot.coreFrame.height - snapshot.actionClipFrame.height) <= 0.5,
                            "\(position) count \(count): core/action heights differ")
                try require(abs(snapshot.coreFrame.height - 28) <= 0.5,
                            "\(position) count \(count): House small controls must stay 28pt high")
                try require(rectsEqual(snapshot.coreBackgroundFrame, snapshot.coreFrame, tolerance: 0.001),
                            "\(position) count \(count): persistent core background must match core geometry: \(snapshot.coreBackgroundFrame) vs \(snapshot.coreFrame)")
                let expectedDuration: CFTimeInterval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                try require(abs(snapshot.animationDuration - expectedDuration) <= 0.001,
                            "\(position) count \(count): reveal must use House fast motion token")
                try require(abs(snapshot.contentFadeDuration - expectedDuration) <= 0.001,
                            "\(position) count \(count): shell and content must share one motion duration")
                try require(abs(snapshot.coreCornerRadius - snapshot.controlRadius) <= 0.5,
                            "\(position) count \(count): core radius must follow House 8pt control radius")

                let coreActionGap: CGFloat
                if position == .left {
                    coreActionGap = snapshot.actionClipFrame.minX - snapshot.coreFrame.maxX
                } else {
                    coreActionGap = snapshot.coreFrame.minX - snapshot.actionClipFrame.maxX
                }
                try require(abs(coreActionGap - snapshot.groupGap) <= 0.5,
                            "\(position) count \(count): core/action gap \(coreActionGap) != \(snapshot.groupGap)")
                let gapX = position == .left
                    ? (snapshot.coreFrame.maxX + snapshot.actionClipFrame.minX) / 2
                    : (snapshot.actionClipFrame.maxX + snapshot.coreFrame.minX) / 2
                let gapPoint = NSPoint(x: gapX, y: snapshot.coreFrame.midY)
                let gapPixel = harness.hub.debugPixel(at: gapPoint)
                try require((gapPixel & 0xff) > 0,
                            "\(position) count \(count): expanded hub gap must belong to the pill surface; point=\(gapPoint) pixel=\(String(gapPixel, radix: 16)) core=\(snapshot.coreFrame) actions=\(snapshot.actionClipFrame)")

                let pills = snapshot.actionPills
                try require(pills.count == 3, "\(position) count \(count): expected 3 action pills")
                for pill in pills {
                    try require(abs(pill.frame.height - snapshot.coreFrame.height) <= 0.5,
                                "\(position) count \(count): \(pill.title) height differs")
                    try require(abs(pill.cornerRadius - snapshot.controlRadius) <= 0.5,
                                "\(position) count \(count): \(pill.title) radius must follow House 8pt control radius")
                    try require(pill.hasIcon,
                                "\(position) count \(count): \(pill.title) must render as an icon+label command pill")
                    try require(pill.labelAlpha == 1 && pill.isInteractive,
                                "\(position) count \(count): fully expanded \(pill.title) should be visible and interactive")
                }
                for index in 1..<pills.count {
                    let gap = pills[index].frame.minX - pills[index - 1].frame.maxX
                    try require(abs(gap - snapshot.actionGap) <= 0.5,
                                "\(position) count \(count): action gap \(gap) != \(snapshot.actionGap)")
                }
            }
        }
    }

    private static func testActionLabelsStayShort() throws {
        let harness = Harness(position: .right)
        harness.hub.debugSetExpansionProgress(1)
        let titles = harness.hub.debugSnapshot().actionPills.map(\.title)
        try require(Set(titles) == Set(["Delete", "Save As", "Copy All"]), "Unexpected action labels: \(titles)")
        try require(titles.allSatisfy { $0.count <= 8 }, "Action labels must stay compact but explicit: \(titles)")
    }

    private static func testHoverBubbleGeometry() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            harness.hub.debugSetExpansionProgress(0)
            var snapshot = harness.hub.debugSnapshot()
            try require(abs(snapshot.bubbleRadius - snapshot.controlRadius - snapshot.shellInset) <= 0.001,
                        "\(position): outer radius must equal button radius + inset")
            try require(snapshot.bubbleAlpha == 0,
                        "\(position): bubble must be absent before hover")

            let compactPaddingPoint = NSPoint(
                x: position == .left ? snapshot.shellBounds.minX + 1 : snapshot.shellBounds.maxX - 1,
                y: snapshot.shellBounds.midY
            )
            try require((harness.hub.debugPixel(at: compactPaddingPoint) & 0xff) == 0,
                        "\(position): compact shell padding must remain transparent")

            harness.hub.debugSetExpansionProgress(0.1)
            snapshot = harness.hub.debugSnapshot()
            try require(snapshot.bubbleAlpha > 0 && snapshot.bubbleAlpha < 1,
                        "\(position): bubble must fade through an intermediate alpha")

            harness.hub.debugSetExpansionProgress(1)
            snapshot = harness.hub.debugSnapshot()
            try require(abs(snapshot.bubbleAlpha - 1) <= 0.001,
                        "\(position): expanded bubble must finish opaque")
        }
    }

    private static func testActionsKeepVisualOrder() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            harness.hub.debugSetExpansionProgress(1)
            let snapshot = harness.hub.debugSnapshot()
            let leftToRight = snapshot.actionPills.sorted { $0.frame.minX < $1.frame.minX }.map(\.title)
            try require(leftToRight == ["Delete", "Save As", "Copy All"],
                        "\(position): actions must stay Delete, Save As, Copy All from left to right; got \(leftToRight)")
        }
    }

    private static func testRevealHasNoIdleTail() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            var widths: [CGFloat] = []
            for progress: CGFloat in [0, 0.25, 0.5, 0.75, 0.88, 1] {
                harness.hub.debugSetExpansionProgress(progress)
                widths.append(harness.hub.debugSnapshot().shellBounds.width)
            }
            for index in 1..<widths.count {
                try require(widths[index] > widths[index - 1] + 0.5,
                            "\(position): reveal stopped changing before completion: \(widths)")
            }
        }
    }

    private static func testInterruptedRevealKeepsProportionalDeadline() throws {
        let harness = Harness(position: .right)
        harness.hub.debugSetExpansionProgress(0)
        let full = harness.hub.debugTransitionDuration(toExpanded: true)
        harness.hub.debugSetExpansionProgress(0.8)
        let remainder = harness.hub.debugTransitionDuration(toExpanded: true)

        let expectedFull: CFTimeInterval =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
        try require(abs(full - expectedFull) <= 0.001,
                    "Full House reveal must use the active motion token")
        try require(abs(remainder - expectedFull * 0.2) <= 0.001,
                    "The last 20% must take 20% of the duration, not restart a full reveal: \(remainder)")
    }

    private static func testSpringRetargetPreservesVelocity() throws {
        let omega: CGFloat = 7 / 0.12
        let forward = nativeHubSpringStep(value: 0,
                                          velocity: 0,
                                          target: 1,
                                          angularFrequency: omega,
                                          deltaTime: 0.01)
        try require(forward.value > 0 && forward.velocity > 0,
                    "Critically damped reveal must respond immediately")

        let reversed = nativeHubSpringStep(value: forward.value,
                                           velocity: forward.velocity,
                                           target: 0,
                                           angularFrequency: omega,
                                           deltaTime: 0.001)
        try require(reversed.value >= forward.value,
                    "Retarget must preserve forward presentation velocity before decelerating")
        try require(reversed.velocity > 0 && reversed.velocity < forward.velocity,
                    "Retarget must decelerate continuously instead of flipping velocity")
    }

    private static func testRepeatedHoverDoesNotRestartReveal() throws {
        let harness = Harness(position: .right)
        harness.hub.debugSetExpansionProgress(0.2)
        harness.hub.debugRequestExpanded(true)
        let starts = harness.hub.debugSnapshot().animationStartCount

        harness.hub.debugSetExpansionProgress(0.3)
        for _ in 0..<20 { harness.hub.debugRequestExpanded(true) }

        try require(harness.hub.debugSnapshot().animationStartCount == starts,
                    "Repeated mouseMoved events restarted the same reveal target")
    }

    private static func testHoverBubbleClosesOutsideFootprint() throws {
        let harness = Harness(position: .right)
        harness.hub.debugSetExpansionProgress(0.2)
        harness.hub.debugRequestExpanded(true)
        harness.hub.debugSetExpansionProgress(0.2)

        let visibleFrame = harness.visibleShellFrameInRoot()
        harness.hub.debugUpdateHover(at: NSPoint(x: visibleFrame.midX,
                                                 y: visibleFrame.midY))
        try require(harness.hub.debugSnapshot().expansionTarget == 1,
                    "Pointer inside the expanded footprint closed the bubble")

        harness.hub.debugUpdateHover(at: NSPoint(x: -1000, y: -1000))
        let closing = harness.hub.debugSnapshot()
        try require(closing.expansionTarget == 0,
                    "Pointer outside the expanded footprint did not retarget the bubble")
        try require(abs(closing.bubbleAlpha - closing.progress) <= 0.001,
                    "Bubble content detached from the shared shell progress while closing")
        harness.hub.debugSetExpansionProgress(0)
        try require(harness.hub.debugSnapshot().bubbleAlpha == 0,
                    "Closed shell did not finish transparent")
    }

    private static func testTrayHoverSessionHoldsHubOpen() throws {
        let harness = Harness(position: .right)
        harness.hub.debugRequestExpanded(true)
        harness.hub.debugSetTrayHoverActive(true)
        harness.hub.debugRequestExpanded(false)

        try require(harness.hub.debugSnapshot().expansionTarget == 1,
                    "Leaving the hub for a card collapsed the shared hover session")

        harness.hub.debugSetTrayHoverActive(false)
        try require(harness.hub.debugSnapshot().expansionTarget == 0,
                    "The hub remained open after the complete tray hover session ended")
    }

    private static func testRevealReusesNativeRender() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            harness.hub.debugSetExpansionProgress(0)
            let initial = harness.hub.debugSnapshot().nativeRenderPassCount
            for progress: CGFloat in [0.08, 0.18, 0.33, 0.55, 0.78, 0.92, 1] {
                harness.hub.debugSetExpansionProgress(progress)
                _ = harness.hub.debugSnapshot()
            }
            let final = harness.hub.debugSnapshot().nativeRenderPassCount
            try require(final - initial <= 1,
                        "\(position): reveal rerendered Native SDK \(final - initial) times instead of clipping one expanded frame")
        }
    }

    private static func testRevealKeepsStaticHostGeometry() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            harness.hub.debugSetExpansionProgress(0)
            let hostFrame = harness.hub.view.frame
            for progress: CGFloat in [0.18, 0.33, 0.55, 0.78, 1] {
                harness.hub.debugSetExpansionProgress(progress)
                try require(rectsEqual(harness.hub.view.frame, hostFrame, tolerance: 0.001),
                            "\(position): reveal resized the AppKit host at progress \(progress)")
            }
        }
    }

    private static func testExpandedRenderFitsFrameBudget() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            harness.hub.debugSetExpansionProgress(0)
            let before = harness.hub.debugSnapshot()
            let startedAt = CACurrentMediaTime()
            harness.hub.debugSetExpansionProgress(0.01)
            let after = harness.hub.debugSnapshot()
            let wallDuration = CACurrentMediaTime() - startedAt
            let renderDuration = after.nativeRenderDuration - before.nativeRenderDuration
            try require(renderDuration <= 1.0 / 60.0,
                        "\(position): first expanded Native SDK render took \(renderDuration * 1000)ms")
            try require(wallDuration <= 1.0 / 30.0,
                        "\(position): first reveal frame took \(wallDuration * 1000)ms end to end")
        }
    }

    private static func testNativeRuntimeOwnsHover() throws {
        let harness = Harness(position: .right)
        harness.hub.debugSetExpansionProgress(1)
        harness.hub.debugHoverButton(title: "Delete")
        let buttons = harness.hub.debugControlButtons()
        let hovered = buttons.filter(\.isHovered).map(\.title)
        try require(hovered == ["Delete"], "Native SDK hover state should belong only to Delete, got \(hovered)")
    }

    private static func testCompactShellUsesOneStroke() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            harness.hub.debugSetExpansionProgress(0)
            let snapshot = harness.hub.debugSnapshot()

            try require(abs(snapshot.shellBorderWidth) <= 0.001,
                        "\(position): House command row must not use container border")
            try require(snapshot.bubbleAlpha == 0,
                        "\(position): compact hub must not show the hover bubble")
            try require(snapshot.coreHasIcon,
                        "\(position): compact hub must keep the trailing chevron")
            try require(snapshot.coreTitle.allSatisfy { $0.isNumber || $0 == "+" },
                        "\(position): compact hub must show only the screenshot count")
        }
    }

    private static func testBlankShellAreaIsInert() throws {
        let progressFrames: [CGFloat] = [0.08, 0.18, 0.33]

        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            var checkedPoints = 0
            for progress in progressFrames {
                harness.hub.debugSetExpansionProgress(progress)
                guard let blankPoint = harness.blankShellPoint() else { continue }
                checkedPoints += 1
                harness.dispatchClickIfPossible(at: blankPoint)
                try require(harness.toggleCount == 0,
                            "\(position) progress \(progress): blank shell click toggled tray")
                try require(harness.deleteCount == 0 && harness.saveAsCount == 0 && harness.copyAllCount == 0,
                            "\(position) progress \(progress): blank shell click triggered action")
            }
            try require(checkedPoints > 0, "\(position): no blank shell point was available to test")
        }
    }

    private static func testInteractiveActionPillsClickDuringReveal() throws {
        let progressFrames: [CGFloat] = [0.33, 0.55, 0.78, 0.95, 0.98]

        for position in [TrayPosition.right, .left, .bottom, .top] {
            var partialTitles = Set<String>()
            for progress in progressFrames {
                for title in ["Delete", "Save As", "Copy All"] {
                    let harness = Harness(position: position)
                    harness.hub.debugSetExpansionProgress(progress)
                    let snapshot = harness.hub.debugSnapshot()
                    guard snapshot.actionPills.first(where: { $0.title == title })?.isInteractive == true else {
                        continue
                    }

                    let point = try harness.actionPoint(title: title)
                    try harness.click(at: point)
                    partialTitles.insert(title)
                    try requireOnlyAction(title, in: harness, context: "\(position) progress \(progress)")
                }
            }

            let nearestTitle = position == .left ? "Delete" : "Copy All"
            try require(partialTitles.contains(nearestTitle),
                        "\(position): the nearest action \(nearestTitle) must become clickable before the fully expanded frame, got \(partialTitles)")
        }
    }

    private static func testActionPressSurvivesShellMouseExit() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            for title in ["Delete", "Save As", "Copy All"] {
                let harness = Harness(position: position)
                harness.hub.debugSetExpansionProgress(1)
                let point = try harness.actionPoint(title: title)

                try harness.pressThenShellExitAndRelease(at: point)

                try requireOnlyAction(title, in: harness, context: "\(position) \(title)")
            }
        }
    }

    private static func pointsEqual(_ a: NSPoint, _ b: NSPoint, tolerance: CGFloat = 0.5) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private static func rectsEqual(_ a: NSRect, _ b: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        pointsEqual(a.origin, b.origin, tolerance: tolerance)
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    private static func rectContains(_ outer: NSRect, _ inner: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        inner.minX >= outer.minX - tolerance
            && inner.minY >= outer.minY - tolerance
            && inner.maxX <= outer.maxX + tolerance
            && inner.maxY <= outer.maxY + tolerance
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private static func requireOnlyAction(_ title: String, in harness: Harness, context: String) throws {
        try require(harness.toggleCount == 0, "\(context): action click must not toggle tray")
        switch title {
        case "Delete":
            try require(harness.deleteCount == 1, "\(context): Delete did not fire once")
            try require(harness.saveAsCount == 0 && harness.copyAllCount == 0,
                        "\(context): Delete fired another action")
        case "Save As":
            try require(harness.saveAsCount == 1, "\(context): Save As did not fire once")
            try require(harness.deleteCount == 0 && harness.copyAllCount == 0,
                        "\(context): Save As fired another action")
        case "Copy All":
            try require(harness.copyAllCount == 1, "\(context): Copy All did not fire once")
            try require(harness.deleteCount == 0 && harness.saveAsCount == 0,
                        "\(context): Copy All fired another action")
        default:
            throw Failure("\(context): unexpected action title \(title)")
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor
    private final class Harness {
        let window: NSWindow
        let root: NSView
        let hub: HubWindow

        var toggleCount = 0
        var deleteCount = 0
        var saveAsCount = 0
        var copyAllCount = 0
        private var heldHit: NSView?
        private var heldPoint: NSPoint = .zero

        init(position: TrayPosition, count: Int = 2, collapsed: Bool = false) {
            TrayPosition.testCurrent = position

            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
            root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 420))
            root.autoresizingMask = [.width, .height]
            window.contentView = root

            hub = HubWindow()
            hub.onClick = { [weak self] in self?.toggleCount += 1 }
            hub.onDelete = { [weak self] in self?.deleteCount += 1 }
            hub.onSaveAs = { [weak self] in self?.saveAsCount += 1 }
            hub.onCopyAll = { [weak self] in self?.copyAllCount += 1 }
            hub.setState(count: count, collapsed: collapsed)
            root.addSubview(hub.view)
            hub.setOrigin(NSPoint(x: 300, y: 40))
            hub.show()
            root.layoutSubtreeIfNeeded()
        }

        func hoverHub() {
            hub.view.mouseMoved(with: event(.mouseMoved, at: hub.center))
            hub.debugSetExpansionProgress(1)
            root.layoutSubtreeIfNeeded()
        }

        func click(at point: NSPoint) throws {
            let pointInHub = hub.view.convert(point, from: root)
            guard let hit = hub.view.hitTest(pointInHub), hit !== hub.view else {
                throw Failure("No interactive view at \(point)")
            }
            hit.mouseDown(with: event(.leftMouseDown, at: point))
            hit.mouseUp(with: event(.leftMouseUp, at: point))
            root.layoutSubtreeIfNeeded()
        }

        func holdCorePress() throws {
            let point = hub.center
            let pointInHub = hub.view.convert(point, from: root)
            guard let hit = hub.view.hitTest(pointInHub), hit !== hub.view else {
                throw Failure("No interactive core view at \(point)")
            }
            heldHit = hit
            heldPoint = point
            hit.mouseDown(with: event(.leftMouseDown, at: point))
        }

        func releaseCorePress() throws {
            guard let heldHit else { throw Failure("No held core press to release") }
            heldHit.mouseUp(with: event(.leftMouseUp, at: heldPoint))
            self.heldHit = nil
            root.layoutSubtreeIfNeeded()
        }

        func dispatchClickIfPossible(at point: NSPoint) {
            let pointInHub = hub.view.convert(point, from: root)
            guard let hit = hub.view.hitTest(pointInHub) else { return }
            hit.mouseDown(with: event(.leftMouseDown, at: point))
            hit.mouseUp(with: event(.leftMouseUp, at: point))
            root.layoutSubtreeIfNeeded()
        }

        func pressThenShellExitAndRelease(at point: NSPoint) throws {
            let pointInHub = hub.view.convert(point, from: root)
            guard let hit = hub.view.hitTest(pointInHub), hit !== hub.view else {
                throw Failure("No interactive view at \(point)")
            }

            hit.mouseDown(with: event(.leftMouseDown, at: point))
            hub.view.mouseExited(with: event(.mouseMoved, at: NSPoint(x: -20, y: -20)))
            hit.mouseUp(with: event(.leftMouseUp, at: point))
            root.layoutSubtreeIfNeeded()
        }

        func firstActionPoint() throws -> NSPoint {
            try actionPoint(title: "Delete")
        }

        func renderedCoreFrameInRoot() -> NSRect {
            hub.view.convert(hub.debugSnapshot().coreFrame, to: root)
        }

        func visibleShellFrameInRoot() -> NSRect {
            hub.view.convert(hub.debugSnapshot().shellBounds, to: root)
        }

        func actionPoint(title: String) throws -> NSPoint {
            let snapshot = hub.debugSnapshot()
            guard let pill = snapshot.actionPills.first(where: { $0.title == title }) else {
                throw Failure("No action pill named \(title)")
            }
            try require(pill.labelAlpha == 1 && pill.isInteractive,
                        "\(title) is not fully visible and interactive")
            let pointInHub = NSPoint(x: snapshot.actionClipFrame.minX + pill.frame.midX,
                                     y: snapshot.actionClipFrame.minY + pill.frame.midY)
            return hub.view.convert(pointInHub, to: root)
        }

        func blankShellPoint() -> NSPoint? {
            let snapshot = hub.debugSnapshot()
            let clip = snapshot.actionClipFrame.insetBy(dx: 2, dy: 2)
            guard clip.width > 0, clip.height > 0 else { return nil }

            var x = clip.minX
            while x <= clip.maxX {
                let pointInHub = NSPoint(x: x, y: clip.midY)
                let hit = hub.view.hitTest(pointInHub)
                if hit == nil || hit === hub.view {
                    return hub.view.convert(pointInHub, to: root)
                }
                x += 2
            }

            return nil
        }

        func requireVisibleDescendantsInsideShell() throws {
            let shellBounds = hub.view.bounds.insetBy(dx: -0.5, dy: -0.5)
            for view in visibleDescendants(of: hub.view) {
                guard let rect = visibleRectInShell(for: view) else { continue }
                try require(rectContains(shellBounds, rect),
                            "\(type(of: view)) visibly escapes shell bounds: \(rect) not inside \(shellBounds)")
            }
        }

        func requireVisibleLabelsAreUnclipped() throws {
            for label in visibleDescendants(of: hub.view) where label is NSTextField && label.alphaValue > 0.01 {
                let fullRect = label.convert(label.bounds, to: hub.view)
                guard let visibleRect = visibleRectInShell(for: label) else {
                    throw Failure("Visible label has no visible rect: \(label)")
                }
                try require(abs(fullRect.width - visibleRect.width) <= 0.5,
                            "Visible label is horizontally clipped: \(visibleRect) of \(fullRect)")
                try require(abs(fullRect.height - visibleRect.height) <= 0.5,
                            "Visible label is vertically clipped: \(visibleRect) of \(fullRect)")
            }
        }

        private func visibleRectInShell(for view: NSView) -> NSRect? {
            var rect = view.convert(view.bounds, to: hub.view)
            var ancestor = view.superview

            while let current = ancestor {
                if current === hub.view {
                    rect = rect.intersection(hub.debugSnapshot().shellBounds)
                    if rect.isNull || rect.width <= 0 || rect.height <= 0 { return nil }
                    break
                }
                if current.layer?.masksToBounds == true {
                    let clip = current.convert(current.bounds, to: hub.view)
                    rect = rect.intersection(clip)
                    if rect.isNull || rect.width <= 0 || rect.height <= 0 { return nil }
                }
                ancestor = current.superview
            }
            return rect
        }

        private func visibleDescendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { child -> [NSView] in
                guard !child.isHidden, child.alphaValue > 0.01 else { return [] }
                let descendants = visibleDescendants(of: child)
                return [child] + descendants
            }
        }

        private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,
                               location: point,
                               modifierFlags: [],
                               timestamp: 0,
                               windowNumber: window.windowNumber,
                               context: nil,
                               eventNumber: 0,
                               clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)!
        }
    }
}
