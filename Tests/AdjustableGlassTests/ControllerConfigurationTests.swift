import XCTest
@_spi(Experimental) @testable import AdjustableGlass

@available(macOS 26.0, *)
final class ControllerConfigurationTests: XCTestCase {
    @MainActor
    func testAppearanceChangeRequiresFullMaterialInstall() {
        let system = GlassEffectController.Configuration(
            appearance: .system
        )
        let light = GlassEffectController.Configuration(
            appearance: .light
        )
        let dark = GlassEffectController.Configuration(
            appearance: .dark
        )

        XCTAssertTrue(
            GlassEffectController.requiresFullMaterialInstall(
                from: system,
                to: light
            )
        )
        XCTAssertTrue(
            GlassEffectController.requiresFullMaterialInstall(
                from: light,
                to: dark
            )
        )
    }

    @MainActor
    func testForcedAppearanceSelectsAtlasCellIndependentlyOfHost() {
        let light = GlassEffectController.frozenAppearanceSelection(for: .light)
        let dark = GlassEffectController.frozenAppearanceSelection(for: .dark)

        XCTAssertTrue(light.resolves(systemIsLight: false))
        XCTAssertFalse(dark.resolves(systemIsLight: true))
    }

    @MainActor
    func testSystemAppearanceFollowsHost() {
        let system = GlassEffectController.frozenAppearanceSelection(for: .system)

        XCTAssertTrue(system.resolves(systemIsLight: true))
        XCTAssertFalse(system.resolves(systemIsLight: false))
    }

    @MainActor
    func testViewPreservesVibrantAppearanceOverride() throws {
        let referenceWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = AdjustableGlassEffectView(
            referenceWindow: referenceWindow
        )
        let requested = try XCTUnwrap(
            NSAppearance(named: .vibrantDark)
        )

        view.appearance = requested

        XCTAssertEqual(
            view.appearance?.name,
            NSAppearance.Name.vibrantDark
        )
    }

    @MainActor
    func testVariantAndEmphasisChangesRequireFullMaterialInstall() {
        let baseline = GlassEffectController.Configuration()
        var clear = baseline
        clear.variant = .clear
        var inactive = baseline
        inactive.emphasis = .muted

        XCTAssertTrue(
            GlassEffectController.requiresFullMaterialInstall(
                from: baseline,
                to: clear
            )
        )
        XCTAssertTrue(
            GlassEffectController.requiresFullMaterialInstall(
                from: baseline,
                to: inactive
            )
        )
    }

    @MainActor
    func testTintAndAmountChangesKeepTheNarrowPath() {
        let baseline = GlassEffectController.Configuration()
        var adjusted = baseline
        adjusted.visibility = 0.42
        adjusted.tint = .systemBlue

        XCTAssertFalse(
            GlassEffectController.requiresFullMaterialInstall(
                from: baseline,
                to: adjusted
            )
        )
    }

    @MainActor
    func testOnlyTintChangesUseFrameCoalescedPresentation() {
        let baseline = GlassEffectController.Configuration(
            tint: NSColor(
                srgbRed: 0.2,
                green: 0.4,
                blue: 0.8,
                alpha: 0.3
            )
        )
        var opacity = baseline
        opacity.tint = baseline.tint?.withAlphaComponent(0.7)
        var color = baseline
        color.tint = NSColor(
            srgbRed: 0.8,
            green: 0.2,
            blue: 0.4,
            alpha: 0.3
        )
        var visibilityAndTint = opacity
        visibilityAndTint.visibility = 0.5

        XCTAssertTrue(
            GlassEffectController.isTintOnlyChange(
                from: baseline,
                to: opacity
            )
        )
        XCTAssertTrue(
            GlassEffectController.isTintOnlyChange(
                from: baseline,
                to: color
            )
        )
        XCTAssertFalse(
            GlassEffectController.isTintOnlyChange(
                from: baseline,
                to: visibilityAndTint
            )
        )
    }

    @MainActor
    func testUnresolvedTintAppliesOnlyWhenResolutionCannotTakeTheRequest() {
        XCTAssertFalse(
            GlassEffectController.tintPreflightRequiresApply(
                tintIsReady: false,
                hasPendingCommitRequest: true
            )
        )
        XCTAssertTrue(
            GlassEffectController.tintPreflightRequiresApply(
                tintIsReady: false,
                hasPendingCommitRequest: false
            )
        )
        XCTAssertTrue(
            GlassEffectController.tintPreflightRequiresApply(
                tintIsReady: true,
                hasPendingCommitRequest: false
            )
        )
    }

    @MainActor
    func testViewCanStartWithoutReferenceAndRebindWithoutReplacingContent() {
        let view = AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        let content = NSView(frame: view.bounds)
        view.contentView = content
        let referenceWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let referenceView = NSView(
            frame: referenceWindow.contentView?.bounds ?? .zero
        )
        referenceWindow.contentView?.addSubview(referenceView)

        XCTAssertNil(view.referenceWindow)
        view.referenceWindow = referenceWindow
        view.referenceView = referenceView
        XCTAssertTrue(view.referenceWindow === referenceWindow)
        XCTAssertTrue(view.referenceView === referenceView)
        XCTAssertTrue(view.contentView === content)

        view.referenceView = nil
        view.referenceWindow = nil
        XCTAssertNil(view.referenceView)
        XCTAssertNil(view.referenceWindow)
        XCTAssertTrue(view.contentView === content)
    }

    @MainActor
    func testViewControllerOwnedWindowAcceptsReferenceViewBeforeAttachment() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let controller = NSViewController()
        controller.view = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentViewController = controller

        XCTAssertNil(AdjustableGlassEffectView.resolveReferenceView(
            referenceWindow: window,
            referenceView: nil
        ))

        let anchor = NSView(frame: .zero)
        let glass = AdjustableGlassEffectView(referenceWindow: window)
        XCTAssertTrue(glass.responds(
            to: NSSelectorFromString("setReferenceView:")
        ))
        glass.setValue(anchor, forKey: "referenceView")
        XCTAssertTrue(glass.referenceView === anchor)
        XCTAssertTrue(AdjustableGlassEffectView.resolveReferenceView(
            referenceWindow: window,
            referenceView: glass.referenceView
        ) === anchor)

        controller.view.addSubview(anchor)
        XCTAssertTrue(anchor.window === window)
        XCTAssertTrue(AdjustableGlassEffectView.resolveReferenceView(
            referenceWindow: window,
            referenceView: glass.referenceView
        ) === anchor)
    }

    @MainActor
    func testPlainAppKitWindowUsesItsContentViewAsReferenceView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(AdjustableGlassEffectView.resolveReferenceView(
            referenceWindow: window,
            referenceView: nil
        ) === window.contentView)
    }

    @MainActor
    func testConfigurationBatchLeavesEveryRequestedPropertyApplied() {
        let view = AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        let tint = NSColor(
            srgbRed: 0.2,
            green: 0.4,
            blue: 0.8,
            alpha: 0.6
        )

        view.performConfigurationUpdates {
            view.style = .clear
            view.appearance = NSAppearance(named: .darkAqua)
            view.effectState = .inactive
            view.effectAmount = 0.42
            view.tintColor = tint
        }

        XCTAssertEqual(view.style, .clear)
        XCTAssertEqual(view.appearance?.name, .darkAqua)
        XCTAssertEqual(view.effectState, .inactive)
        XCTAssertEqual(view.effectAmount, 0.42, accuracy: 0.0001)
        XCTAssertTrue(view.tintColor?.isEqual(tint) == true)
    }

    @MainActor
    func testConfigurationBatchCoalescesMaterialRefreshes() async {
        let view = AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        let initialGeneration = view.materialRefreshGeneration

        view.performConfigurationUpdates {
            view.style = .clear
            view.appearance = NSAppearance(named: .darkAqua)
        }

        XCTAssertEqual(view.materialRefreshGeneration, initialGeneration)
        await Task.yield()
        XCTAssertEqual(view.materialRefreshGeneration, initialGeneration + 1)
    }

    @MainActor
    func testNativeLayoutInsetTracksSelectedParticipation() {
        let view = AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        view.experimentalMarginWidth = nil
        view.style = .regular
        view.effectState = .active
        view.layoutSubtreeIfNeeded()
        let activeInset = view.requiredWindowInset

        view.effectState = .inactive
        view.layoutSubtreeIfNeeded()
        let inactiveInset = view.requiredWindowInset

        XCTAssertGreaterThan(activeInset, inactiveInset)
        XCTAssertEqual(
            inactiveInset,
            GlassEffectController.windowInset(
                for: 0,
                osMajorVersion: ProcessInfo.processInfo
                    .operatingSystemVersion.majorVersion
            )
        )
    }

    @MainActor
    func testPreAtlasInsetCoversTheMacOS26Envelope() {
        let controller = GlassEffectController(
            hostWindow: nil,
            configuration: nil,
            storageURL: nil,
            certifiedAtlasURLs: GlassMaterialAtlasCatalog.bundledAtlasURLs()
        )
        defer { controller.invalidate() }

        XCTAssertEqual(
            controller.requiredWindowInset(
                for: CGSize(width: 320, height: 120)
            ),
            81
        )
    }

    @MainActor
    func testRenderExperimentDisablesOnlySelectedPassGates() {
        let source = GlassMaterialStyleSample(
            shortSide: 120,
            numeric: [
                "inputFaceOpacity": 1,
                "inputShadowOpacity": 0.4,
                "inputSDRShadowOpacity": 0.2,
                "inputRingShadowOpacity": 0.06,
                "inputBleedOpacity": 0.53,
                "inputOuterRefractionAmount": 24,
            ],
            colors: [:],
            points: [:],
            nilKeys: [],
            marginWidth: 83,
            outputMinimum: -10_000,
            outputMaximum: 1,
            matrices: [],
            rims: []
        )

        let shadowless = GlassMaterialRenderExperiment(
            outerPasses: .all.subtracting(.shadow)
        ).applying(to: source)
        XCTAssertEqual(shadowless.numeric["inputShadowOpacity"], 0)
        XCTAssertEqual(shadowless.numeric["inputSDRShadowOpacity"], 0)
        XCTAssertEqual(shadowless.numeric["inputRingShadowOpacity"], 0.06)
        XCTAssertEqual(shadowless.numeric["inputBleedOpacity"], 0.53)
        XCTAssertEqual(
            shadowless.numeric["inputOuterRefractionAmount"],
            24
        )

        let ringless = GlassMaterialRenderExperiment(
            outerPasses: .all.subtracting(.ringShadow)
        ).applying(to: source)
        XCTAssertEqual(ringless.numeric["inputRingShadowOpacity"], 0)
        XCTAssertEqual(ringless.numeric["inputShadowOpacity"], 0.4)

        let bleedless = GlassMaterialRenderExperiment(
            outerPasses: .all.subtracting(.bleed)
        ).applying(to: source)
        XCTAssertEqual(bleedless.numeric["inputBleedOpacity"], 0)
        XCTAssertEqual(bleedless.numeric["inputShadowOpacity"], 0.4)

        let noOuterRefraction = GlassMaterialRenderExperiment(
            outerPasses: .all.subtracting(.outerRefraction)
        ).applying(to: source)
        XCTAssertEqual(
            noOuterRefraction.numeric["inputOuterRefractionAmount"],
            0
        )
        XCTAssertEqual(noOuterRefraction.numeric["inputBleedOpacity"], 0.53)
    }

    @MainActor
    func testExperimentalMarginOverridesOnlyTheEffectiveWindowInset() {
        let view = AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        let nativeInset = view.experimentalNativeRequiredWindowInset

        view.experimentalMarginWidth = 12

        XCTAssertEqual(view.requiredWindowInset, 13)
        XCTAssertEqual(view.experimentalNativeRequiredWindowInset, nativeInset)
        XCTAssertGreaterThan(nativeInset, view.requiredWindowInset)

        view.experimentalMarginWidth = nil
        XCTAssertEqual(view.requiredWindowInset, nativeInset)
    }

    @MainActor
    func testZeroExperimentalMarginUsesThePlatformSafetyInset() {
        let view = AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )

        view.experimentalMarginWidth = 0

        XCTAssertEqual(
            view.requiredWindowInset,
            GlassEffectController.windowInset(
                for: 0,
                osMajorVersion: ProcessInfo.processInfo
                    .operatingSystemVersion.majorVersion
            )
        )
    }

    func testProductPolicyDisablesOnlyTheOuterShadow() {
        let contained = GlassMaterialRenderExperiment.outerShadowPolicy(
            hasOuterShadow: false
        )

        XCTAssertFalse(contained.outerPasses.contains(.shadow))
        XCTAssertTrue(contained.outerPasses.contains(.ringShadow))
        XCTAssertTrue(contained.outerPasses.contains(.bleed))
        XCTAssertTrue(contained.outerPasses.contains(.outerRefraction))
        XCTAssertEqual(contained.marginWidthOverride, 0)

        let native = GlassMaterialRenderExperiment.outerShadowPolicy(
            hasOuterShadow: true
        )
        XCTAssertEqual(native.outerPasses, .all)
        XCTAssertNil(native.marginWidthOverride)
    }

    func testZeroMarginSafetyInsetDiffersByMajorVersion() {
        XCTAssertEqual(
            GlassEffectController.windowInset(for: 0, osMajorVersion: 26),
            0
        )
        XCTAssertEqual(
            GlassEffectController.windowInset(for: 0, osMajorVersion: 27),
            1
        )
        XCTAssertEqual(
            GlassEffectController.windowInset(for: 12.25, osMajorVersion: 26),
            14
        )
        XCTAssertEqual(
            GlassEffectController.windowInset(for: 12.25, osMajorVersion: 27),
            14
        )
    }

    @MainActor
    func testHasOuterShadowControlsTheDerivedWindowInset() {
        let view = AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        let containedInset = GlassEffectController.windowInset(
            for: 0,
            osMajorVersion: ProcessInfo.processInfo
                .operatingSystemVersion.majorVersion
        )

        XCTAssertFalse(view.hasOuterShadow)
        XCTAssertEqual(view.requiredWindowInset, containedInset)

        view.hasOuterShadow = true
        XCTAssertEqual(
            view.requiredWindowInset,
            view.experimentalNativeRequiredWindowInset
        )

        view.hasOuterShadow = false
        XCTAssertEqual(view.requiredWindowInset, containedInset)
    }
}
