import AppKit
import XCTest
@testable import AdjustableGlass

@available(macOS 26.0, *)
final class MaterialInstallationReconcilerTests: XCTestCase {
    @MainActor
    func testCommittedIdentityRequiresEveryAuthorityAndLiveHealth() {
        let firstDestination = NSObject()
        let secondDestination = NSObject()
        let configuration = GlassEffectController.Configuration(
            visibility: 0.8,
            tint: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.6)
        )
        let tintKey = SIMD3<Double>(0.2, 0.4, 0.8)
        let committed = MaterialInstallationReconciler.CommittedIdentity(
            destination: ObjectIdentifier(firstDestination),
            configuration: configuration,
            baseGeneration: 7,
            displayedTintKey: tintKey
        )

        func isCurrent(
            committed candidate: MaterialInstallationReconciler
                .CommittedIdentity? = committed,
            destination: NSObject = firstDestination,
            configuration candidateConfiguration:
                GlassEffectController.Configuration = configuration,
            baseGeneration: Int = 7,
            displayedTintKey: SIMD3<Double>? = tintKey,
            pairedCoverageComplete: Bool = true,
            liveTreeHoldsPlan: Bool = true
        ) -> Bool {
            MaterialInstallationReconciler.isAlreadyCurrent(
                committed: candidate,
                destination: ObjectIdentifier(destination),
                configuration: candidateConfiguration,
                baseGeneration: baseGeneration,
                displayedTintKey: displayedTintKey,
                pairedCoverageComplete: pairedCoverageComplete,
                liveTreeHoldsPlan: liveTreeHoldsPlan
            )
        }

        XCTAssertTrue(isCurrent())
        XCTAssertFalse(isCurrent(committed: nil))
        XCTAssertFalse(isCurrent(destination: secondDestination))
        XCTAssertFalse(isCurrent(
            configuration: .init(visibility: 0.7, tint: configuration.tint)
        ))
        XCTAssertFalse(isCurrent(baseGeneration: 8))
        XCTAssertFalse(isCurrent(
            displayedTintKey: SIMD3<Double>(0.21, 0.4, 0.8)
        ))
        XCTAssertFalse(isCurrent(pairedCoverageComplete: false))
        XCTAssertFalse(isCurrent(liveTreeHoldsPlan: false))
    }
}
