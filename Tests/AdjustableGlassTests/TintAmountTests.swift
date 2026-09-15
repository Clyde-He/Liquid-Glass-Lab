import AppKit
import XCTest
@testable import AdjustableGlass

@available(macOS 27.0, *)
final class TintAmountTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else {
            throw XCTSkip("Glass tint amount validation is specific to macOS 27")
        }
    }

    private struct Reference: Decodable {
        var amount: Double
        var cell: GlassMaterialStyleAtlas.Cell
        var expected: GlassMaterialStyleSample
        var scale: Double
    }

    @MainActor
    private func atlas() throws -> GlassMaterialStyleAtlas {
        let url = try XCTUnwrap(GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 27))
        return try JSONDecoder().decode(GlassMaterialStyleAtlas.self, from: Data(contentsOf: url))
    }

    /// One generated fixture covers every product-reachable non-midpoint row
    /// in canonical Golden, including held-out sizes, amounts and scale gates.
    @MainActor
    func testReplayMatchesCanonicalNativeCoordinates() throws {
        let model = try XCTUnwrap(GlassMaterialTintAmount.bundled)
        let base = try atlas()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "native-tint-amount", withExtension: "json"))
        let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: url))
        XCTAssertFalse(references.isEmpty)
        for reference in references {
            let sample = try XCTUnwrap(base.sample(for: reference.cell, at: reference.expected.shortSide))
            let actual = try XCTUnwrap(model.applying(to: sample, cell: reference.cell, amount: reference.amount))
            let label = "\(reference.cell) S=\(sample.shortSide) t=\(reference.amount)"
            XCTAssertEqual(actual.numeric.keys.sorted(), reference.expected.numeric.keys.sorted(), label)
            for (key, value) in reference.expected.numeric {
                XCTAssertEqual(try XCTUnwrap(actual.numeric[key]), value, accuracy: 1e-6, "\(label) \(key)")
            }
            for (key, color) in reference.expected.colors {
                let read = try XCTUnwrap(actual.colors[key])
                for (a,b) in zip([read.red,read.green,read.blue,read.alpha], [color.red,color.green,color.blue,color.alpha]) {
                    XCTAssertEqual(a,b,accuracy:1e-6,"\(label) \(key)")
                }
            }
            XCTAssertEqual(actual.marginWidth, reference.expected.marginWidth, accuracy: 1e-6, label)
            XCTAssertEqual(actual.matrices, reference.expected.matrices, label)
            XCTAssertEqual(actual.rims, reference.expected.rims, label)
            XCTAssertEqual(actual.outputMinimum, reference.expected.outputMinimum, accuracy: 1e-6, label)
            XCTAssertEqual(actual.outputMaximum, reference.expected.outputMaximum, accuracy: 1e-6, label)
            XCTAssertEqual(actual.nilKeys, reference.expected.nilKeys, label)
            XCTAssertEqual(
                GlassMaterialTintAmount.backdropScale(
                    for: actual,
                    isClear: reference.cell.isClear
                ),
                reference.scale,
                label
            )
        }
    }

    @MainActor
    func testMidpointPreservesEveryCatalogCoordinate() throws {
        let model = try XCTUnwrap(GlassMaterialTintAmount.bundled)
        let base = try atlas()
        for entry in model.entries {
            let sample = try XCTUnwrap(base.sample(for: entry.cell, at: entry.shortSide))
            let actual = try XCTUnwrap(model.applying(to: sample, cell: entry.cell, amount: 0.5))
            for (key, expected) in sample.numeric {
                XCTAssertEqual(try XCTUnwrap(actual.numeric[key]), expected, accuracy: 1e-6, key)
            }
            XCTAssertEqual(actual.marginWidth, sample.marginWidth, accuracy: 1e-6)
        }
    }

    @MainActor
    func testClearBoundariesAndMarginDoNotInterpolateGates() throws {
        let model = try XCTUnwrap(GlassMaterialTintAmount.bundled)
        let cell = GlassMaterialStyleAtlas.Cell(isLightAppearance:true,isClear:true,hasMainParticipation:true)
        let base = try XCTUnwrap(try atlas().sample(for:cell,at:200))
        let zero = try XCTUnwrap(model.applying(to:base,cell:cell,amount:0))
        let positive = try XCTUnwrap(model.applying(to:base,cell:cell,amount:0.0001))
        let midpoint = try XCTUnwrap(model.applying(to:base,cell:cell,amount:0.5))
        let upper = try XCTUnwrap(model.applying(to:base,cell:cell,amount:0.5001))
        XCTAssertEqual(zero.numeric["inputBlurOpacity0"],0)
        XCTAssertEqual(positive.numeric["inputBlurOpacity0"],1)
        XCTAssertEqual(positive.numeric["inputBlurOpacity1"],0.5)
        XCTAssertEqual(midpoint.numeric["inputBlurFillBlurRadius"],0)
        XCTAssertEqual(upper.numeric["inputBlurFillBlurRadius"],8)
        XCTAssertEqual(midpoint.marginWidth,0.5)
        XCTAssertEqual(upper.marginWidth,16)
    }

    @MainActor
    func testAmountChangesAreDistinctInstallIdentities() {
        let old = GlassEffectController.Configuration(tintAmount:0.25)
        var new = old
        new.tintAmount = 0.75
        XCTAssertNotEqual(old,new)
        XCTAssertTrue(GlassEffectController.requiresFullMaterialInstall(from:old,to:new))
        new.tint = .red
        XCTAssertFalse(GlassEffectController.isTintOnlyChange(from:old,to:new))
    }

    @MainActor
    func testResolvedAmountCallbackReportsEffectiveChangesAndCoalescesBatches() throws {
        let glass = AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        glass.tintAmount = 0
        var observed: [CGFloat?] = []
        glass.onResolvedTintAmountChange = { observed.append($0) }

        glass.tintAmount = 0.25
        glass.tintAmount = 0.25
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(try XCTUnwrap(observed[0]), 0.25, accuracy: 1e-6)

        observed.removeAll()
        glass.performConfigurationUpdates {
            glass.tintAmount = 0.5
            glass.tintAmount = 0.75
        }
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(try XCTUnwrap(observed[0]), 0.75, accuracy: 1e-6)

        let systemAmount = GlassSystemTintAmount.read() ?? 0.5
        glass.tintAmount = systemAmount < 0.5 ? 1 : 0
        observed.removeAll()
        glass.tintAmount = nil
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(observed[0]),
            systemAmount,
            accuracy: 1e-6
        )

        glass.tintAmount = systemAmount < 0.5 ? 1 : 0
        observed.removeAll()
        NotificationCenter.default.post(
            name: GlassSystemTintAmount.didChange,
            object: nil
        )
        XCTAssertTrue(observed.isEmpty)
    }

    @MainActor
    func testSystemReaderUsesRegistrationDefaultsAndRejectsInvalidValues() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "glass-tint-test-\(UUID().uuidString)"))
        defaults.setVolatileDomain(["NSGlassTintAmount":0.25],forName:UserDefaults.argumentDomain)
        XCTAssertEqual(GlassSystemTintAmount.read(defaults:defaults),0.25)
        defaults.setVolatileDomain(["NSGlassTintAmount":"unreadable"],forName:UserDefaults.argumentDomain)
        XCTAssertNil(GlassSystemTintAmount.read(defaults:defaults))
        defaults.setVolatileDomain(["NSGlassTintAmount":0.25],forName:UserDefaults.argumentDomain)
        XCTAssertNil(GlassSystemTintAmount.read(defaults:defaults, osMajor:26))
        XCTAssertEqual(GlassSystemTintAmount.read(defaults:defaults, osMajor:27),0.25)
    }

    @MainActor
    func testManualAmountRepairsNativeRestampOnSystemNotification() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let glass = AdjustableGlassEffectView(
            frame: NSRect(x: 20, y: 20, width: 320, height: 200)
        )
        glass.tintAmount = 0.4
        window.contentView?.addSubview(glass)
        window.orderFront(nil)
        for _ in 0..<100 {
            glass.layoutSubtreeIfNeeded()
            if glass.materialStrength.frozenStyleIsCurrentlyApplied { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(glass.materialStrength.frozenStyleIsCurrentlyApplied)
        let originalGeneration = glass.effectControllerGeneration
        let expectedMargin = try XCTUnwrap(GlassMaterialAccess.marginWidth(under: glass))

        // Unlike a preference-only test, damage the actual native tree first.
        // Do not yield after the notification: the 1-second guard must not
        // be what repairs the material while a wrong frame is presented.
        for notification in [GlassSystemTintAmount.didChange, UserDefaults.didChangeNotification] {
            let target = try XCTUnwrap(GlassMaterialAccess.glassBackgroundTarget(under: glass))
            GlassMaterialAccess.write(0.9, forKey: "inputBlurFillNormalOpacity", to: target)
            GlassMaterialAccess.setMarginWidth(expectedMargin + 16, under: glass)
            XCTAssertFalse(glass.materialStrength.frozenStyleIsCurrentlyApplied)
            NotificationCenter.default.post(name: notification, object: nil)
            let repaired = try XCTUnwrap(GlassMaterialAccess.glassBackgroundTarget(under: glass))
            XCTAssertEqual(try XCTUnwrap(GlassMaterialAccess.readNumbers(from: repaired)["inputBlurFillNormalOpacity"]), 0.4, accuracy: 1e-6)
            XCTAssertEqual(try XCTUnwrap(GlassMaterialAccess.marginWidth(under: glass)), expectedMargin, accuracy: 1e-6)
            XCTAssertEqual(glass.tintAmount, 0.4)
            XCTAssertEqual(glass.effectControllerGeneration, originalGeneration)
        }

        // The shader can be correct while backdrop downsampling still follows
        // the system. This was invisible to the previous frozen readback.
        GlassMaterialAccess.setBackdropScale(0.125, under: glass)
        XCTAssertFalse(glass.materialStrength.frozenStyleIsCurrentlyApplied)
        NotificationCenter.default.post(name: GlassSystemTintAmount.didChange, object: nil)
        XCTAssertEqual(try XCTUnwrap(GlassMaterialAccess.backdropScale(under: glass)), 0.5, accuracy: 1e-6)

        glass.tintAmount = 1
        for _ in 0..<100 {
            glass.layoutSubtreeIfNeeded()
            if glass.materialStrength.frozenStyleIsCurrentlyApplied { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Native Materialize keeps the endpoint's sampling bucket, including
        // at g=0, rather than estimating it from the animated shader inputs.
        for progress in [0.0, 0.25, 0.75, 1.0] {
            glass.effectAmount = progress
            XCTAssertEqual(try XCTUnwrap(GlassMaterialAccess.backdropScale(under: glass)), 0.125)
            GlassMaterialAccess.setBackdropScale(0.5, under: glass)
            XCTAssertFalse(glass.materialStrength.frozenStyleIsCurrentlyApplied)
            NotificationCenter.default.post(name: GlassSystemTintAmount.didChange, object: nil)
            XCTAssertEqual(try XCTUnwrap(GlassMaterialAccess.backdropScale(under: glass)), 0.125)
        }
    }

    @MainActor
    func testNonfiniteInputAndIncompleteModelCannotProduceInvalidMaterial() throws {
        XCTAssertEqual(GlassMaterialTintAmount.normalize(.nan),0.5)
        XCTAssertEqual(GlassMaterialTintAmount.normalize(.infinity),1)
        XCTAssertEqual(GlassMaterialTintAmount.normalize(-.infinity),0)
        var model = try XCTUnwrap(GlassMaterialTintAmount.bundled)
        model.entries.removeLast()
        XCTAssertFalse(model.isValid)
    }
}
