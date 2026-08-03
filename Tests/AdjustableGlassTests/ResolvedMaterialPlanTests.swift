import AppKit
import Foundation
import XCTest
@testable import AdjustableGlass

/// Step 2 unit coverage for the source-neutral material plan and the pure
/// product-status mapping. The plan builder is the sole site deriving
/// ready/held/unresolved presentation, the native alpha-0 staging color, and
/// the displayed RGB key; the status mapper is a pure function over an
/// explicit snapshot that never schedules. The redundant-apply recovery
/// ownership regression exercises the controller through a Tint the pipeline
/// cannot represent, so the bounded legacy capture is the only progression
/// owner.
@available(macOS 26.0, *)
final class ResolvedMaterialPlanTests: XCTestCase {
    // MARK: - Plan derivation

    private struct PlanCase {
        var name: String
        var tint: NSColor?
        var baseIsPaired: Bool
        var requestedCovered: Bool
        var requestedHasPending: Bool
        var held: NSColor?
        var heldCovered: Bool
        var expectedPresentation: ResolvedMaterialPlan.TintPresentation
        var expectedTintIsReady: Bool
        var expectedHasPending: Bool
        var expectedDisplayedTint: NSColor?
        var expectedDisplayedTintKey: SIMD3<Double>?
        var expectedNativeTint: NSColor?
        var expectedInstallableAtlas: Bool
    }

    @MainActor
    func testPlanDerivationIsTableDrivenAndSourceNeutral() throws {
        let requested = NSColor(srgbRed: 0.08, green: 0.78, blue: 0.71, alpha: 0.63)
        let held = NSColor(srgbRed: 0.9, green: 0.2, blue: 0.4, alpha: 0.4)
        let atlas = GlassMaterialStyleAtlas()

        func state(
            isReady: Bool,
            covered: Bool,
            hasPending: Bool
        ) -> TintResolutionPipeline.ResolutionState {
            TintResolutionPipeline.ResolutionState(
                isReady: isReady,
                installableAtlas: covered ? atlas : nil,
                displayedColor: covered ? requested : nil,
                hasPendingRequest: hasPending
            )
        }
        func heldState(
            covered: Bool
        ) -> TintResolutionPipeline.ResolutionState {
            TintResolutionPipeline.ResolutionState(
                isReady: covered,
                installableAtlas: covered ? atlas : nil,
                displayedColor: covered ? held : nil,
                hasPendingRequest: false
            )
        }

        let cases: [PlanCase] = [
            PlanCase(
                name: "no tint",
                tint: nil,
                baseIsPaired: false,
                requestedCovered: false,
                requestedHasPending: false,
                held: nil,
                heldCovered: false,
                expectedPresentation: .none,
                expectedTintIsReady: true,
                expectedHasPending: false,
                expectedDisplayedTint: nil,
                expectedDisplayedTintKey: nil,
                expectedNativeTint: nil,
                expectedInstallableAtlas: false
            ),
            PlanCase(
                name: "verified requested color",
                tint: requested,
                baseIsPaired: true,
                requestedCovered: true,
                requestedHasPending: false,
                held: held,
                heldCovered: true,
                expectedPresentation: .ready,
                expectedTintIsReady: true,
                expectedHasPending: false,
                expectedDisplayedTint: requested,
                expectedDisplayedTintKey: rgbKey(requested),
                expectedNativeTint: requested,
                expectedInstallableAtlas: true
            ),
            PlanCase(
                name: "verified requested color with stale pending request",
                tint: requested,
                baseIsPaired: true,
                requestedCovered: true,
                requestedHasPending: true,
                held: nil,
                heldCovered: false,
                expectedPresentation: .ready,
                expectedTintIsReady: true,
                expectedHasPending: true,
                expectedDisplayedTint: requested,
                expectedDisplayedTintKey: rgbKey(requested),
                expectedNativeTint: requested,
                expectedInstallableAtlas: true
            ),
            PlanCase(
                name: "held last verified color while newer color resolves",
                tint: requested,
                baseIsPaired: true,
                requestedCovered: false,
                requestedHasPending: true,
                held: held,
                heldCovered: true,
                expectedPresentation: .held,
                expectedTintIsReady: false,
                expectedHasPending: true,
                expectedDisplayedTint: held,
                expectedDisplayedTintKey: rgbKey(held),
                expectedNativeTint: held,
                expectedInstallableAtlas: true
            ),
            PlanCase(
                name: "held color no longer installable falls to unresolved",
                tint: requested,
                baseIsPaired: true,
                requestedCovered: false,
                requestedHasPending: true,
                held: held,
                heldCovered: false,
                expectedPresentation: .unresolved,
                expectedTintIsReady: false,
                expectedHasPending: true,
                expectedDisplayedTint: nil,
                expectedDisplayedTintKey: nil,
                expectedNativeTint: requested.withAlphaComponent(0),
                expectedInstallableAtlas: false
            ),
            PlanCase(
                name: "no held color means unresolved staging at alpha 0",
                tint: requested,
                baseIsPaired: true,
                requestedCovered: false,
                requestedHasPending: false,
                held: nil,
                heldCovered: false,
                expectedPresentation: .unresolved,
                expectedTintIsReady: false,
                expectedHasPending: false,
                expectedDisplayedTint: nil,
                expectedDisplayedTintKey: nil,
                expectedNativeTint: requested.withAlphaComponent(0),
                expectedInstallableAtlas: false
            ),
            PlanCase(
                name: "synthesized coverage without a verified base is not ready",
                tint: requested,
                baseIsPaired: false,
                requestedCovered: true,
                requestedHasPending: false,
                held: nil,
                heldCovered: false,
                expectedPresentation: .unresolved,
                expectedTintIsReady: false,
                expectedHasPending: false,
                expectedDisplayedTint: nil,
                expectedDisplayedTintKey: nil,
                expectedNativeTint: requested.withAlphaComponent(0),
                expectedInstallableAtlas: false
            ),
            PlanCase(
                name: "held presentation survives an unverified base",
                tint: requested,
                baseIsPaired: false,
                requestedCovered: false,
                requestedHasPending: false,
                held: held,
                heldCovered: true,
                expectedPresentation: .held,
                expectedTintIsReady: false,
                expectedHasPending: false,
                expectedDisplayedTint: held,
                expectedDisplayedTintKey: rgbKey(held),
                expectedNativeTint: held,
                expectedInstallableAtlas: true
            ),
        ]

        for entry in cases {
            let configuration = GlassEffectController.Configuration(
                tint: entry.tint
            )
            let plan = ResolvedMaterialPlan.build(
                configuration: configuration,
                baseIsPairedCoverageComplete: entry.baseIsPaired,
                requestedState: state(
                    isReady: entry.tint == nil
                        || (entry.baseIsPaired && entry.requestedCovered),
                    covered: entry.requestedCovered,
                    hasPending: entry.requestedHasPending
                ),
                heldState: entry.held.map { _ in heldState(
                    covered: entry.heldCovered
                ) },
                lastVerifiedTintColor: entry.held
            )
            XCTAssertEqual(
                plan.presentation,
                entry.expectedPresentation,
                entry.name
            )
            XCTAssertEqual(
                plan.tintIsReady,
                entry.expectedTintIsReady,
                entry.name
            )
            XCTAssertEqual(
                plan.hasPendingCommitRequest,
                entry.expectedHasPending,
                entry.name
            )
            XCTAssertTrue(
                colorsMatch(plan.displayedTint, entry.expectedDisplayedTint),
                "\(entry.name): displayedTint"
            )
            XCTAssertEqual(
                plan.displayedTintKey,
                entry.expectedDisplayedTintKey,
                entry.name
            )
            XCTAssertTrue(
                colorsMatch(plan.nativeTintColor, entry.expectedNativeTint),
                "\(entry.name): nativeTintColor"
            )
            XCTAssertEqual(
                plan.installableAtlas != nil,
                entry.expectedInstallableAtlas,
                entry.name
            )
        }
    }

    // MARK: - Pure status mapping

    private struct StatusCase {
        var name: String
        var snapshot: StatusSnapshot
        var expectedStatus: GlassEffectController.Status
        var expectedRequestsScheduling: Bool
    }

    @MainActor
    func testStatusMappingIsTableDrivenAndNeverSchedules() {
        func snapshot(
            hasView: Bool = true,
            captureActive: Bool = false,
            tintUnverified: Bool = false,
            hostParticipates: Bool = false,
            hasBudget: Bool = true,
            providerState: GlassMaterialAtlasProvider.State = .ready,
            source: GlassEffectController.Source = .certifiedCatalog,
            acceptingRestamp: Bool = false,
            frozen: Bool = true
        ) -> StatusSnapshot {
            StatusSnapshot(
                hasView: hasView,
                isLegacyCaptureActive: captureActive,
                tintIsUnverified: tintUnverified,
                hostParticipates: hostParticipates,
                legacyCaptureHasBudget: hasBudget,
                providerState: providerState,
                source: source,
                acceptingSuccessfulTintRestamp: acceptingRestamp,
                frozenStyleIsCurrentlyApplied: frozen
            )
        }

        let cases: [StatusCase] = [
            StatusCase(
                name: "no view is idle before everything",
                snapshot: snapshot(hasView: false),
                expectedStatus: .idle,
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "no view wins over an active capture",
                snapshot: snapshot(hasView: false, captureActive: true),
                expectedStatus: .idle,
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "an active capture locks",
                snapshot: snapshot(captureActive: true),
                expectedStatus: .lockingTint,
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "an active capture wins over an unresolved tint",
                snapshot: snapshot(
                    captureActive: true,
                    tintUnverified: true,
                    hostParticipates: true
                ),
                expectedStatus: .lockingTint,
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "unverified tint without a host waits",
                snapshot: snapshot(tintUnverified: true),
                expectedStatus: .waitingForMainWindow,
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "unverified tint without a host waits regardless of budget",
                snapshot: snapshot(tintUnverified: true, hasBudget: false),
                expectedStatus: .waitingForMainWindow,
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "unverified tint with a host but no budget falls back",
                snapshot: snapshot(
                    tintUnverified: true,
                    hostParticipates: true,
                    hasBudget: false
                ),
                expectedStatus: .fallback(.tintNotYetVerified),
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "unverified tint with a host and budget locks and requests recovery",
                snapshot: snapshot(
                    tintUnverified: true,
                    hostParticipates: true
                ),
                expectedStatus: .lockingTint,
                expectedRequestsScheduling: true
            ),
            StatusCase(
                name: "unverified tint beats a ready provider",
                snapshot: snapshot(
                    tintUnverified: true,
                    hostParticipates: true,
                    providerState: .ready
                ),
                expectedStatus: .lockingTint,
                expectedRequestsScheduling: true
            ),
            StatusCase(
                name: "unverified tint beats a failed provider",
                snapshot: snapshot(
                    tintUnverified: true,
                    hostParticipates: true,
                    providerState: .failed("boom")
                ),
                expectedStatus: .lockingTint,
                expectedRequestsScheduling: true
            ),
            StatusCase(
                name: "idle provider",
                snapshot: snapshot(providerState: .idle),
                expectedStatus: .idle,
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "provider waits for its own main window",
                snapshot: snapshot(providerState: .waitingForMainWindow),
                expectedStatus: .waitingForMainWindow,
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "provider capturing reports calibration progress",
                snapshot: snapshot(
                    providerState: .capturing(completed: 2, total: 8)
                ),
                expectedStatus: .calibrating(completed: 2, total: 8),
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "ready provider with the one-turn restamp receipt",
                snapshot: snapshot(acceptingRestamp: true, frozen: false),
                expectedStatus: .ready(source: .certifiedCatalog),
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "ready provider with live frozen-style health",
                snapshot: snapshot(frozen: true),
                expectedStatus: .ready(source: .certifiedCatalog),
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "ready provider without receipt or live health fails closed",
                snapshot: snapshot(frozen: false),
                expectedStatus: .fallback(.frozenInstallFailed),
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "ready provider carries the source provenance",
                snapshot: snapshot(source: .runtimeCalibration),
                expectedStatus: .ready(source: .runtimeCalibration),
                expectedRequestsScheduling: false
            ),
            StatusCase(
                name: "failed provider reports calibration failure",
                snapshot: snapshot(providerState: .failed("cache write failed")),
                expectedStatus: .fallback(.calibrationFailed("cache write failed")),
                expectedRequestsScheduling: false
            ),
        ]

        for entry in cases {
            let resolution = StatusMapper.resolve(entry.snapshot)
            XCTAssertEqual(
                resolution.status,
                entry.expectedStatus,
                entry.name
            )
            XCTAssertEqual(
                resolution.requestsLegacyCaptureScheduling,
                entry.expectedRequestsScheduling,
                entry.name
            )
        }
    }

    // MARK: - Redundant-apply recovery ownership

    /// The redundant-apply early return must not strand recovery: it still
    /// applies the full pure status decision — and, when that decision
    /// requests it, the bounded legacy capture scheduling — instead of
    /// skipping the status owner. A pattern-image Tint is deliberately used:
    /// `GlassMaterialColorValue` rejects pattern colors, so the pipeline can
    /// never record a fast-path request or warm probes, which is exactly the
    /// state in which a skipped status decision would leave the unresolved
    /// Tint with no progression owner at all.
    @MainActor
    func testRedundantApplyOwnsRecoveryThroughThePureStatusDecision()
        async throws {
        let (window, glass) = makeRealWindowAndGlass()
        defer {
            window.orderOut(nil)
            glass.materialStrength.invalidate()
        }
        // Let the tree and the view's own controller settle first, so the
        // first install holds immediately and the install-retry storm never
        // starts — keeping the redundant-apply path below deterministic.
        try? await Task.sleep(for: .milliseconds(1500))
        let controller = try makeController(tint: patternTint())
        controller.attach(to: glass)
        guard await waitForFrozenStyle(on: glass) else {
            XCTFail("frozen style never installed on the real tree")
            return
        }
        let freezeCount = controller.tintDiagnostics.fullFreezeCount
        XCTAssertEqual(
            controller.status,
            .waitingForMainWindow,
            "an unverified Tint with no participating host must hold the "
                + "pure waiting decision"
        )

        // Duplicate readiness for identical requested and displayed state hits
        // the redundant-apply early return: no re-freeze, and the pure status
        // decision is still applied rather than skipped.
        controller.ensureReady()
        XCTAssertEqual(controller.tintDiagnostics.fullFreezeCount, freezeCount)
        XCTAssertEqual(controller.status, .waitingForMainWindow)

        // Wait past the bounded legacy capture's first retry beat: the capture
        // (scheduled by the freeze-install owner because the pattern Tint can
        // never record a fast-path request) fires without a host, reports the
        // host-waiting step, and the pure decision holds — nothing has
        // re-frozen or dropped the Tint.
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(controller.status, .waitingForMainWindow)
        XCTAssertEqual(controller.tintDiagnostics.fullFreezeCount, freezeCount)
    }

    // MARK: - Fixtures

    private func rgbKey(_ color: NSColor) -> SIMD3<Double>? {
        GlassMaterialColorValue(color).map(TintResolutionPipeline.rgbKey)
    }

    private func colorsMatch(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard let left = GlassMaterialColorValue(lhs),
              let right = GlassMaterialColorValue(rhs)
        else { return false }
        return left.red == right.red
            && left.green == right.green
            && left.blue == right.blue
            && left.alpha == right.alpha
    }

    /// A color the pipeline cannot represent: `usingColorSpace(.extendedSRGB)`
    /// returns nil for a pattern color, so `GlassMaterialColorValue` rejects
    /// it, no fast-path request can ever be recorded, and the bounded legacy
    /// capture becomes the only progression owner.
    private func patternTint() -> NSColor {
        NSColor(patternImage: NSImage(size: NSSize(width: 8, height: 8)))
    }

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

    private func makeController(tint: NSColor?) throws -> GlassEffectController {
        // The certified fixture is loaded lazily by the provider during the
        // first attach, so the temporary directory must outlive this method.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let bundledURL = try XCTUnwrap(
            GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 27)
        )
        var atlas = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: Data(contentsOf: bundledURL)
        )
        atlas.environment = .current(for: nil)
        let certifiedURL = directory.appendingPathComponent("certified.json")
        try JSONEncoder().encode(atlas).write(to: certifiedURL)
        return GlassEffectController(
            hostWindow: nil,
            configuration: .init(tint: tint),
            storageURL: directory.appendingPathComponent("runtime.json"),
            certifiedAtlasURLs: [certifiedURL]
        )
    }
}
