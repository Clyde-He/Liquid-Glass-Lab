import XCTest
@testable import AdjustableGlass

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
}
