import AppKit
import Foundation
import XCTest
@_spi(Experimental) @testable import AdjustableGlass

/// Lifecycle regressions for the reference-host contract: the reference
/// window and probe view are a calibration/resolver capability, never
/// ownership of the rendered material. Detaching, replacing, or re-setting
/// the same host must not rebuild the effect controller, invalidate the
/// verified material, or re-run capture/freeze work for identical state.
@available(macOS 26.0, *)
final class ReferenceLifecycleTests: XCTestCase {
    // MARK: - Atomic pair updates

    @MainActor
    func testSetReferenceHostIsAtomicAndDoesNotRebuildController() {
        let view = makeGlassView()
        let (window, anchor) = makeReferenceHost()

        view.setReferenceHost(window: window, view: anchor)

        XCTAssertEqual(view.effectControllerGeneration, 1)
        XCTAssertEqual(view.referenceHostUpdateCount, 1)
        XCTAssertTrue(view.referenceWindow === window)
        XCTAssertTrue(view.referenceView === anchor)
    }

    @MainActor
    func testSetReferenceHostWithSamePairIsANoOp() {
        let view = makeGlassView()
        let (window, anchor) = makeReferenceHost()

        view.setReferenceHost(window: window, view: anchor)
        view.setReferenceHost(window: window, view: anchor)
        view.referenceWindow = window
        view.referenceView = anchor

        XCTAssertEqual(view.effectControllerGeneration, 1)
        XCTAssertEqual(view.referenceHostUpdateCount, 1)
    }

    @MainActor
    func testEffectivePairIdentityIgnoresRedundantExplicitView() {
        let view = makeGlassView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // With no content-view controller and no explicit referenceView, the
        // effective probe host is the window's own content view. Setting the
        // same content view explicitly must not count as a host transition.
        view.setReferenceHost(window: window, view: nil)
        XCTAssertEqual(view.referenceHostUpdateCount, 1)

        view.referenceView = window.contentView
        XCTAssertEqual(view.referenceHostUpdateCount, 1)
    }

    @MainActor
    func testIndividualReferencePropertiesStillRebind() {
        let view = makeGlassView()
        let (window, anchor) = makeReferenceHost()

        view.referenceWindow = window
        XCTAssertEqual(view.referenceHostUpdateCount, 1)
        XCTAssertEqual(view.effectControllerGeneration, 1)

        view.referenceView = anchor
        XCTAssertEqual(view.referenceHostUpdateCount, 2)
        XCTAssertEqual(view.effectControllerGeneration, 1)
    }

    // MARK: - Detach and replacement

    @MainActor
    func testClosingReferenceWindowDetachesWithoutRebuildingController() {
        let view = makeGlassView()
        let (window, anchor) = makeReferenceHost()
        view.setReferenceHost(window: window, view: anchor)
        let insetBefore = view.experimentalNativeRequiredWindowInset
        let statusBefore = view.status

        window.close()

        XCTAssertNil(view.referenceWindow)
        XCTAssertEqual(view.effectControllerGeneration, 1)
        XCTAssertEqual(view.status, statusBefore)
        XCTAssertNotEqual(view.status, .idle)
        // The verified base atlas still resolves the same window room: the
        // rendered material did not disappear with the host.
        XCTAssertEqual(view.experimentalNativeRequiredWindowInset, insetBefore)
    }

    @MainActor
    func testReplacementReferenceHostReattachesWithoutRebuild() {
        let view = makeGlassView()
        let (window, anchor) = makeReferenceHost()
        let (replacement, replacementAnchor) = makeReferenceHost()
        view.setReferenceHost(window: window, view: anchor)
        window.close()

        view.setReferenceHost(window: replacement, view: replacementAnchor)

        XCTAssertEqual(view.effectControllerGeneration, 1)
        // attach, detach, then reattach — one transition each, no rebuilds.
        XCTAssertEqual(view.referenceHostUpdateCount, 3)
        XCTAssertTrue(view.referenceWindow === replacement)
        XCTAssertTrue(view.referenceView === replacementAnchor)
        XCTAssertNotEqual(view.status, .idle, "controller must not be destroyed")
    }

    @MainActor
    func testRepeatedPrepareIfNeededIsIdempotent() {
        let view = makeGlassView()
        let (window, anchor) = makeReferenceHost()
        view.setReferenceHost(window: window, view: anchor)
        view.prepareIfNeeded()
        let generation = view.effectControllerGeneration
        let updates = view.referenceHostUpdateCount

        for _ in 0..<5 {
            view.prepareIfNeeded()
        }

        XCTAssertEqual(view.effectControllerGeneration, generation)
        XCTAssertEqual(view.referenceHostUpdateCount, updates)
    }

    @MainActor
    func testRepeatedEnsureReadyDoesNotRefreeze() async throws {
        let (window, glass) = makeRealWindowAndGlass()
        defer {
            window.orderOut(nil)
            glass.materialStrength.invalidate()
        }
        let controller = try makeController()
        controller.attach(to: glass)
        controller.ensureReady()
        guard await waitForFrozenStyle(on: glass) else {
            XCTFail("frozen style never installed on the real tree")
            return
        }
        let freezeCount = controller.tintDiagnostics.fullFreezeCount

        // Duplicate readiness work for an unchanged controller must not re-run
        // the capture/freeze transaction.
        for _ in 0..<5 {
            controller.ensureReady()
        }
        XCTAssertEqual(controller.tintDiagnostics.fullFreezeCount, freezeCount)
    }

    // MARK: - Controller rebind semantics

    @MainActor
    func testControllerRebindSamePairReturnsFalse() throws {
        let controller = try makeController()
        let (window, anchor) = makeReferenceHost()
        controller.rebindReferenceHost(hostWindow: window, probeHostView: anchor)
        let expectedPair = controller.hostWindow

        XCTAssertFalse(controller.rebindReferenceHost(
            hostWindow: window,
            probeHostView: anchor
        ))
        XCTAssertTrue(controller.hostWindow === expectedPair)
    }

    @MainActor
    func testControllerDetachAndReplacementKeepVerifiedBaseAndSkipFreeze() async throws {
        let (window, glass) = makeRealWindowAndGlass()
        defer {
            window.orderOut(nil)
            glass.materialStrength.invalidate()
        }
        let controller = try makeController()
        controller.attach(to: glass)
        controller.ensureReady()
        guard await waitForFrozenStyle(on: glass) else {
            XCTFail("frozen style never installed on the real tree")
            return
        }
        let (hostWindow, anchor) = makeReferenceHost()
        controller.rebindReferenceHost(hostWindow: hostWindow, probeHostView: anchor)
        let freezeCount = controller.tintDiagnostics.fullFreezeCount
        let insetBefore = glass.experimentalNativeRequiredWindowInset

        // Detaching the host must not invalidate the installed material or
        // re-run the freeze for unchanged state.
        controller.rebindReferenceHost(hostWindow: nil, probeHostView: nil)
        XCTAssertNil(controller.hostWindow)
        XCTAssertEqual(controller.tintDiagnostics.fullFreezeCount, freezeCount)
        XCTAssertEqual(glass.experimentalNativeRequiredWindowInset, insetBefore)

        // A replacement host re-targets calibration without restamping.
        let (replacement, replacementAnchor) = makeReferenceHost()
        controller.rebindReferenceHost(
            hostWindow: replacement,
            probeHostView: replacementAnchor
        )
        XCTAssertTrue(controller.hostWindow === replacement)
        XCTAssertTrue(controller.probeHostView === replacementAnchor)
        XCTAssertEqual(controller.tintDiagnostics.fullFreezeCount, freezeCount)
    }

    @MainActor
    func testUnresolvedTintWaitsForHostWhileBaseMaterialHolds() async throws {
        let (window, glass) = makeRealWindowAndGlass()
        defer {
            window.orderOut(nil)
            glass.materialStrength.invalidate()
        }
        let controller = try makeController(
            tint: outOfDomainColor()
        )
        controller.attach(to: glass)
        controller.ensureReady()
        guard await waitForFrozenStyle(on: glass) else {
            XCTFail("frozen style never installed on the real tree")
            return
        }
        let (hostWindow, anchor) = makeReferenceHost()
        controller.rebindReferenceHost(hostWindow: hostWindow, probeHostView: anchor)
        let freezeCount = controller.tintDiagnostics.fullFreezeCount

        // The certified base is installed once; the out-of-domain Tint has no
        // verified matrices and no participating host, so the controller must
        // wait — without re-freezing the base.
        controller.ensureReady()
        XCTAssertEqual(controller.tintDiagnostics.fullFreezeCount, freezeCount)
        XCTAssertGreaterThan(glass.experimentalNativeRequiredWindowInset, 0)
    }

    @MainActor
    func testRedundantApplyRequiresLiveFrozenStyle() async throws {
        let (window, glass) = makeRealWindowAndGlass()
        defer {
            window.orderOut(nil)
            glass.materialStrength.invalidate()
        }
        let controller = try makeController()
        controller.attach(to: glass)
        controller.ensureReady()
        guard await waitForFrozenStyle(on: glass) else {
            XCTFail("frozen style never installed on the real tree")
            return
        }
        let installedCount = controller.tintDiagnostics.fullFreezeCount

        // The requested state stays identical; only the material-strength
        // frozen state is dropped, as if AppKit rebuilt the private tree.
        glass.materialStrength.invalidate()
        XCTAssertFalse(glass.materialStrength.frozenStyleIsCurrentlyApplied)

        // The live-tree check must turn the redundant apply into a real
        // re-freeze that restores the frozen style.
        controller.ensureReady()
        XCTAssertEqual(
            controller.tintDiagnostics.fullFreezeCount,
            installedCount + 1
        )
        guard await waitForFrozenStyle(on: glass) else {
            XCTFail("re-freeze did not restore the frozen style")
            return
        }

        // With the style restored, the next identical ensure is idempotent.
        controller.ensureReady()
        XCTAssertEqual(
            controller.tintDiagnostics.fullFreezeCount,
            installedCount + 1
        )
    }

    @MainActor
    func testResolvedTintEndsTheWaitingStateWithoutAHost() throws {
        let view = makeGlassView()
        let controller = try makeController(
            tint: outOfDomainColor(),
            withVerifiedTintInCache: true
        )
        controller.attach(to: view)

        // The cached verified Tint makes coverage complete even with no host:
        // the state must leave "waiting for reference window".
        view.prepareIfNeeded()
        XCTAssertNotEqual(view.status, .waitingForReferenceWindow)
        XCTAssertNotEqual(
            view.status,
            .unavailable(.tintResolutionFailed),
            "cached verified Tint must not report as unverified"
        )
    }

    // MARK: - Provider rebind semantics

    @MainActor
    func testProviderRebindKeepsVerifiedAtlasAndCachedTint() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, _) = try makeCertifiedFixture(in: directory)
        let cacheURL = directory.appendingPathComponent("runtime.json")
        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
        provider.ensureCaptured()
        let color = outOfDomainColor()
        let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
        let matrices = tintMatrices(for: sourceColor, seed: 0.35)
        XCTAssertTrue(provider.persistVerifiedTintMatrices(
            sourceColor: sourceColor,
            matrices: matrices,
            captureEnvironment: .current(for: nil)
        ))

        let (window, anchor) = makeReferenceHost()
        provider.rebindReferenceHost(hostWindow: window, probeHostView: anchor)
        provider.rebindReferenceHost(hostWindow: nil, probeHostView: nil)
        let (replacement, replacementAnchor) = makeReferenceHost()
        provider.rebindReferenceHost(
            hostWindow: replacement,
            probeHostView: replacementAnchor
        )

        XCTAssertTrue(provider.hostWindow === replacement)
        XCTAssertTrue(provider.probeHostView === replacementAnchor)
        XCTAssertEqual(provider.state, .ready)
        XCTAssertEqual(provider.atlasSource, .certified)
        XCTAssertEqual(provider.atlas.tintMatrixColorCount, 1)
        for cell in GlassMaterialStyleAtlas.allTintCells {
            XCTAssertEqual(
                provider.atlas.tintMatrix(for: cell, matching: color),
                matrices[cell]
            )
        }
    }

    @MainActor
    func testProviderRebindSamePairReturnsFalse() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, _) = try makeCertifiedFixture(in: directory)
        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            certifiedAtlasURLs: [certifiedURL]
        )
        let (window, anchor) = makeReferenceHost()
        provider.rebindReferenceHost(hostWindow: window, probeHostView: anchor)

        XCTAssertFalse(provider.rebindReferenceHost(
            hostWindow: window,
            probeHostView: anchor
        ))
    }

    // MARK: - Fixtures

    @MainActor
    private func makeGlassView() -> AdjustableGlassEffectView {
        AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
    }

    /// A window ordered front so AppKit materializes the private glass tree,
    /// which `frozenStyleIsCurrentlyApplied` and the freeze readback need.
    @MainActor
    private func makeRealWindowAndGlass() -> (NSWindow, AdjustableGlassEffectView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let glass = AdjustableGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        window.contentView?.addSubview(glass)
        window.orderFront(nil)
        return (window, glass)
    }

    /// Polls until the frozen style reads back on the real tree. The strength
    /// writer heals AppKit's margin re-derivation on its own beats, so the
    /// first poll that sees the full style holds is the stable one.
    @MainActor
    private func waitForFrozenStyle(
        on glass: AdjustableGlassEffectView,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            glass.layoutSubtreeIfNeeded()
            if glass.materialStrength.frozenStyleIsCurrentlyApplied {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @MainActor
    private func makeReferenceHost() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let anchor = NSView(
            frame: window.contentView?.bounds ?? .zero
        )
        window.contentView?.addSubview(anchor)
        return (window, anchor)
    }

    private func makeController(
        tint: NSColor? = nil,
        withVerifiedTintInCache: Bool = false
    ) throws -> GlassEffectController {
        let directory = try makeTemporaryDirectory()
        let (certifiedURL, _) = try makeCertifiedFixture(in: directory)
        let cacheURL = directory.appendingPathComponent("runtime.json")
        if withVerifiedTintInCache {
            var cached = try JSONDecoder().decode(
                GlassMaterialStyleAtlas.self,
                from: Data(contentsOf: certifiedURL)
            )
            let color = outOfDomainColor()
            let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
            for (cell, matrix) in tintMatrices(
                for: sourceColor,
                seed: 0.35
            ) {
                cached.addTintMatrix(
                    .init(sourceColor: sourceColor, matrix: matrix),
                    for: cell
                )
            }
            try JSONEncoder().encode(cached).write(to: cacheURL)
        }
        return GlassEffectController(
            hostWindow: nil,
            configuration: .init(tint: tint),
            storageURL: cacheURL,
            certifiedAtlasURLs: [certifiedURL]
        )
    }

    private func outOfDomainColor() -> NSColor {
        NSColor(
            colorSpace: .extendedSRGB,
            components: [1.4, -0.4, 0.2, 0.6],
            count: 4
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeCertifiedFixture(
        in directory: URL
    ) throws -> (URL, GlassMaterialStyleAtlas) {
        let bundledURL = try XCTUnwrap(
            GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 27)
        )
        var atlas = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: Data(contentsOf: bundledURL)
        )
        atlas.environment = .current(for: nil)
        let url = directory.appendingPathComponent("certified.json")
        try JSONEncoder().encode(atlas).write(to: url)
        return (url, atlas)
    }

    private func tintMatrices(
        for sourceColor: GlassMaterialColorValue,
        seed: Float
    ) -> [GlassMaterialStyleAtlas.Cell: [Float]] {
        Dictionary(uniqueKeysWithValues: GlassMaterialStyleAtlas.allTintCells
            .enumerated().map { index, cell in
                var matrix = (0..<20).map { coefficient in
                    seed + Float(index) * 0.01 + Float(coefficient) * 0.0001
                }
                matrix[18] = Float(sourceColor.alpha)
                return (cell, matrix)
            })
    }
}
