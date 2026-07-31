import XCTest
@testable import AdjustableGlass

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

        XCTAssertNil(view.referenceWindow)
        view.referenceWindow = referenceWindow
        XCTAssertTrue(view.referenceWindow === referenceWindow)
        XCTAssertTrue(view.contentView === content)

        view.referenceWindow = nil
        XCTAssertNil(view.referenceWindow)
        XCTAssertTrue(view.contentView === content)
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
    func testLayoutInsetTracksSelectedParticipation() {
        let view = AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        view.style = .regular
        view.effectState = .active
        view.layoutSubtreeIfNeeded()
        let activeInset = view.requiredWindowInset

        view.effectState = .inactive
        view.layoutSubtreeIfNeeded()
        let inactiveInset = view.requiredWindowInset

        XCTAssertGreaterThan(activeInset, inactiveInset)
        XCTAssertGreaterThanOrEqual(inactiveInset, 1)
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
}
