import AppKit
import Foundation
import XCTest
@testable import AdjustableGlass

/// Step 0/Step 1 characterization of the Tint resolution surface, before the
/// pipeline extraction: locks down the pure, externally observable contract a
/// `TintResolutionPipeline` must preserve. Cadence and presentation policy
/// (display-link ownership, held-color presentation) are deliberately out of
/// scope here.
///
/// This suite only covers behavior not already locked down elsewhere:
/// persistence/load and cache admission are exercised end-to-end in
/// CatalogTests, and controller-level precedence is covered in
/// TintMatrixSynthesizerTests. Here the same contracts are pinned at the
/// pure seams a pipeline extraction must preserve — the static resolution
/// function, the alpha patch, the overlay admission gate, and the provider's
/// readiness/persistence callbacks.
@available(macOS 26.0, *)
final class TintResolutionCharacterizationTests: XCTestCase {
    // MARK: - Source precedence

    /// A certified major must prefer the accepted closed form even when the
    /// runtime cache holds the exact RGB, and the value-semantic resolution
    /// must never mutate the provider's reusable base.
    @MainActor
    func testCertifiedSynthesisWinsOverExactCachedOverlayOnSupportedMajor()
        throws {
        var atlas = try makeBaseAtlas()
        let color = NSColor(
            srgbRed: 0.08,
            green: 0.78,
            blue: 0.71,
            alpha: 0.63
        )
        let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
        let cachedMatrix = [Float](repeating: 0.25, count: 20)
        for cell in GlassMaterialStyleAtlas.allTintCells {
            atlas.addTintMatrix(
                .init(sourceColor: sourceColor, matrix: cachedMatrix),
                for: cell
            )
        }

        for emphasis in [
            GlassEffectController.Emphasis.normal,
            .muted,
        ] {
            let resolved = try XCTUnwrap(
                GlassEffectController.resolvedTintAtlas(
                    atlas,
                    color: color,
                    emphasis: emphasis,
                    osMajorVersion: 27
                ),
                "synthesis must resolve an in-domain color on a certified major"
            )
            let hasMainParticipation = emphasis == .normal
            for cell in cells(hasMainParticipation: hasMainParticipation) {
                let expected = try XCTUnwrap(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: color,
                        cell: cell,
                        osMajorVersion: 27
                    )
                )
                XCTAssertEqual(
                    resolved.tintMatrix(for: cell, matching: color),
                    expected
                )
                XCTAssertNotEqual(
                    resolved.tintMatrix(for: cell, matching: color),
                    cachedMatrix
                )
            }
        }

        // Resolution is value-semantic: the provider's atlas still serves the
        // cached overlay and was never overwritten by the synthesized copy.
        for cell in GlassMaterialStyleAtlas.allTintCells {
            XCTAssertEqual(
                atlas.tintMatrix(for: cell, matching: color),
                cachedMatrix
            )
        }
    }

    // MARK: - Emphasis-isolated coverage

    /// Resolution requires complete coverage of exactly the emphasis's own
    /// participation branch. A Main-Off-only overlay resolves muted and fails
    /// closed for normal; a single missing cell inside the branch fails closed
    /// for that branch while the other branch still resolves.
    @MainActor
    func testEmphasisCoverageIsBranchIsolated() throws {
        let color = outOfDomainColor()

        var mainOffOnly = tintMatrices(for: color, seed: 0.35)
        for cell in mainOffOnly.keys where cell.hasMainParticipation {
            mainOffOnly[cell] = nil
        }
        try assertResolution(
            overlay: mainOffOnly,
            sourceColor: color,
            resolvesEmphasis: .muted,
            failsEmphasis: .normal
        )

        var missingMainOffCell = tintMatrices(for: color, seed: 0.35)
        missingMainOffCell[
            GlassMaterialStyleAtlas.Cell(
                isLightAppearance: false,
                isClear: true,
                hasMainParticipation: false
            )
        ] = nil
        try assertResolution(
            overlay: missingMainOffCell,
            sourceColor: color,
            resolvesEmphasis: .normal,
            failsEmphasis: .muted
        )

        var missingMainOnCell = tintMatrices(for: color, seed: 0.35)
        missingMainOnCell[
            GlassMaterialStyleAtlas.Cell(
                isLightAppearance: true,
                isClear: false,
                hasMainParticipation: true
            )
        ] = nil
        try assertResolution(
            overlay: missingMainOnCell,
            sourceColor: color,
            resolvesEmphasis: .muted,
            failsEmphasis: .normal
        )
    }

    // MARK: - Provider readiness and persistence callbacks

    /// Repeated readiness reads over an already-ready provider must not
    /// re-run the certified-candidate load (no duplicate scheduling).
    @MainActor
    func testRepeatedProviderReadinessReadsDoNotRescheduleCertifiedLoad()
        throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, _) = try makeCertifiedFixture(in: directory)
        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            certifiedAtlasURLs: [certifiedURL]
        )
        var atlasUpdateCount = 0
        provider.onAtlasUpdated = { _ in atlasUpdateCount += 1 }

        provider.ensureCaptured()
        XCTAssertEqual(provider.state, .ready)
        XCTAssertEqual(provider.atlasSource, .certified)
        XCTAssertEqual(atlasUpdateCount, 1)

        for _ in 0..<5 {
            provider.ensureCaptured()
        }
        XCTAssertEqual(provider.state, .ready)
        XCTAssertEqual(provider.atlasSource, .certified)
        XCTAssertEqual(
            atlasUpdateCount,
            1,
            "status/readiness reads must not duplicate the certified load"
        )
    }

    /// Persisting a verified Tint overlay must not fire `onAtlasUpdated`: the
    /// controller treats that callback as a base-material change and would
    /// turn the narrow Tint restamp into a full freeze. The overlay update is
    /// synchronous and published by the provider's own atlas value.
    @MainActor
    func testPersistVerifiedTintMatricesDoesNotFireAtlasUpdated() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, _) = try makeCertifiedFixture(in: directory)
        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: directory.appendingPathComponent("runtime.json"),
            certifiedAtlasURLs: [certifiedURL]
        )
        var atlasUpdateCount = 0
        provider.onAtlasUpdated = { _ in atlasUpdateCount += 1 }
        provider.ensureCaptured()
        XCTAssertEqual(atlasUpdateCount, 1)

        let sourceColor = outOfDomainColor()
        XCTAssertTrue(provider.persistVerifiedTintMatrices(
            sourceColor: sourceColor,
            matrices: tintMatrices(for: sourceColor, seed: 0.35),
            captureEnvironment: .current(for: nil)
        ))
        XCTAssertEqual(
            atlasUpdateCount,
            1,
            "a Tint-only persistence must not signal a base-material change"
        )
        XCTAssertEqual(provider.atlas.tintMatrixColorCount, 1)
    }

    /// `recalibrate` is the recovery entry point: it discards the in-memory
    /// candidate and its provenance so the next host opportunity captures
    /// fresh, and overlay persistence fails closed while no verified base is
    /// loaded.
    @MainActor
    func testRecalibrateDiscardsInMemoryCandidateAndFailsOverlayClosed()
        throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (certifiedURL, _) = try makeCertifiedFixture(in: directory)
        let provider = GlassMaterialAtlasProvider(
            hostWindow: nil,
            storageURL: directory.appendingPathComponent("runtime.json"),
            certifiedAtlasURLs: [certifiedURL]
        )
        provider.ensureCaptured()
        XCTAssertEqual(provider.state, .ready)
        XCTAssertEqual(provider.atlasSource, .certified)

        provider.recalibrate()
        XCTAssertTrue(provider.atlas.isEmpty)
        XCTAssertEqual(provider.atlasSource, .none)
        // Host-less recovery waits for a participating host to capture into.
        XCTAssertEqual(provider.state, .waitingForMainWindow)

        let sourceColor = outOfDomainColor()
        XCTAssertFalse(provider.persistVerifiedTintMatrices(
            sourceColor: sourceColor,
            matrices: tintMatrices(for: sourceColor, seed: 0.35),
            captureEnvironment: .current(for: nil)
        ))
        XCTAssertEqual(provider.atlas.tintMatrixColorCount, 0)
    }

    // MARK: - Coefficient-18 alpha contract

    /// Alpha outside `0...1`, non-finite, is a hard fail-closed condition for
    /// synthesis on both certified majors; the boundaries 0 and 1 resolve and
    /// land exactly in coefficient 18.
    @MainActor
    func testSynthesizerRejectsInvalidAlphaAndAcceptsBoundaryAlpha() throws {
        let cell = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: true,
            isClear: false,
            hasMainParticipation: true
        )
        for invalidAlpha: Double in [-0.001, 1.001, .nan, .infinity] {
            let invalid = GlassMaterialColorValue(
                red: 0.8,
                green: 0.3,
                blue: 0.1,
                alpha: invalidAlpha
            )
            for osMajorVersion in [26, 27] {
                XCTAssertNil(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: invalid,
                        cell: cell,
                        osMajorVersion: osMajorVersion
                    )
                )
            }
        }

        for boundaryAlpha: Double in [0, 1] {
            let boundary = GlassMaterialColorValue(
                red: 0.8,
                green: 0.3,
                blue: 0.1,
                alpha: boundaryAlpha
            )
            for osMajorVersion in [26, 27] {
                let matrix = try XCTUnwrap(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: boundary,
                        cell: cell,
                        osMajorVersion: osMajorVersion
                    )
                )
                XCTAssertEqual(
                    matrix[18],
                    Float(boundaryAlpha),
                    "coefficient 18 must carry alpha exactly"
                )
            }
        }
    }

    /// Changing only alpha must change exactly one coefficient of the
    /// synthesized matrix — index 18, to the exact float — for every context
    /// family on both certified majors.
    @MainActor
    func testSynthesizerAlphaLandsExactlyInCoefficient18AcrossFamilies()
        throws {
        let chromatic = [0.9, 0.3, 0.2]
        let achromatic = [0.5, 0.5, 0.5]
        let darkRegularMainOn = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: false,
            isClear: false,
            hasMainParticipation: true
        )
        let lightRegularMainOn = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: true,
            isClear: false,
            hasMainParticipation: true
        )
        let lightRegularMainOff = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: true,
            isClear: false,
            hasMainParticipation: false
        )

        let cases: [
            (osMajorVersion: Int, cell: GlassMaterialStyleAtlas.Cell, rgb: [Double])
        ] = [
            (27, lightRegularMainOn, chromatic),
            (27, darkRegularMainOn, chromatic),
            (27, lightRegularMainOff, chromatic),
            (27, lightRegularMainOn, achromatic),
            (26, lightRegularMainOn, chromatic),
            (26, lightRegularMainOff, chromatic),
            (26, darkRegularMainOn, achromatic),
        ]

        for entry in cases {
            let base = GlassMaterialColorValue(
                red: entry.rgb[0],
                green: entry.rgb[1],
                blue: entry.rgb[2],
                alpha: 0.25
            )
            let high = GlassMaterialColorValue(
                red: entry.rgb[0],
                green: entry.rgb[1],
                blue: entry.rgb[2],
                alpha: 0.9
            )
            let baseMatrix = try XCTUnwrap(
                GlassMaterialTintMatrixSynthesizer.matrix(
                    for: base,
                    cell: entry.cell,
                    osMajorVersion: entry.osMajorVersion
                )
            )
            let highMatrix = try XCTUnwrap(
                GlassMaterialTintMatrixSynthesizer.matrix(
                    for: high,
                    cell: entry.cell,
                    osMajorVersion: entry.osMajorVersion
                )
            )
            for coefficient in baseMatrix.indices where coefficient != 18 {
                XCTAssertEqual(
                    baseMatrix[coefficient],
                    highMatrix[coefficient],
                    "alpha must not touch coefficient \(coefficient)"
                )
            }
            XCTAssertEqual(baseMatrix[18], 0.25)
            XCTAssertEqual(highMatrix[18], 0.9)
        }
    }

    /// The controller's alpha patch is the runtime half of the coefficient-18
    /// contract: it replaces exactly coefficient 18 with the requested alpha
    /// and refuses anything that cannot be represented. (The valid-path half
    /// is also exercised end-to-end in CatalogTests.)
    @MainActor
    func testAlphaPatchChangesOnlyCoefficient18AndRejectsInvalidAlpha()
        throws {
        var matrix = [Float](repeating: 0.125, count: 20)
        matrix[18] = 0.5

        let patched = try XCTUnwrap(
            GlassEffectController.tintMatrixByPatchingAlpha(
                matrix,
                sourceColor: GlassMaterialColorValue(
                    red: 0.8,
                    green: 0.3,
                    blue: 0.1,
                    alpha: 0.3
                )
            )
        )
        XCTAssertEqual(patched[18], 0.3)
        for coefficient in matrix.indices where coefficient != 18 {
            XCTAssertEqual(patched[coefficient], matrix[coefficient])
        }

        for invalidAlpha: Double in [-0.01, 1.01, .nan, .infinity] {
            XCTAssertNil(
                GlassEffectController.tintMatrixByPatchingAlpha(
                    matrix,
                    sourceColor: GlassMaterialColorValue(
                        red: 0.8,
                        green: 0.3,
                        blue: 0.1,
                        alpha: invalidAlpha
                    )
                )
            )
        }
        XCTAssertNil(
            GlassEffectController.tintMatrixByPatchingAlpha(
                [Float](repeating: 0, count: 19),
                sourceColor: GlassMaterialColorValue(
                    red: 0.8,
                    green: 0.3,
                    blue: 0.1,
                    alpha: 0.3
                )
            )
        )
    }

    /// The overlay admission seam enforces the same gate the live resolver
    /// must: a complete eight-cell set whose coefficient 18 carries the source
    /// alpha. Anything less — a missing cell, a mismatched coefficient 18, or
    /// an invalid source alpha — is rejected outright. (The same gate is
    /// exercised through the persistence path in CatalogTests.)
    @MainActor
    func testVerifiedOverlayAdmissionRequiresCompleteSetAndCoefficient18Match()
        throws {
        let atlas = try makeBaseAtlas()
        let sourceColor = GlassMaterialColorValue(
            red: 1.4,
            green: -0.4,
            blue: 0.2,
            alpha: 0.25
        )
        let matrices = tintMatrices(for: sourceColor, seed: 0.35)
        let admitted = try XCTUnwrap(
            atlas.addingVerifiedTintMatrixSet(
                sourceColor: sourceColor,
                matrices: matrices
            )
        )
        XCTAssertEqual(admitted.tintMatrixColorCount, 1)
        for cell in GlassMaterialStyleAtlas.allTintCells {
            XCTAssertEqual(
                admitted.tintMatrix(for: cell, matching: sourceColor.nsColor),
                matrices[cell]
            )
        }

        var wrongAlpha = matrices
        wrongAlpha[GlassMaterialStyleAtlas.allTintCells[0]]?[18] = 0.5
        XCTAssertNil(
            atlas.addingVerifiedTintMatrixSet(
                sourceColor: sourceColor,
                matrices: wrongAlpha
            )
        )

        var incomplete = matrices
        incomplete[GlassMaterialStyleAtlas.allTintCells[3]] = nil
        XCTAssertNil(
            atlas.addingVerifiedTintMatrixSet(
                sourceColor: sourceColor,
                matrices: incomplete
            )
        )

        let invalidSource = GlassMaterialColorValue(
            red: 1.4,
            green: -0.4,
            blue: 0.2,
            alpha: 1.5
        )
        XCTAssertNil(
            atlas.addingVerifiedTintMatrixSet(
                sourceColor: invalidSource,
                matrices: tintMatrices(for: invalidSource, seed: 0.35)
            )
        )
    }

    // MARK: - Fixtures

    private func assertResolution(
        overlay: [GlassMaterialStyleAtlas.Cell: [Float]],
        sourceColor: GlassMaterialColorValue,
        resolvesEmphasis: GlassEffectController.Emphasis,
        failsEmphasis: GlassEffectController.Emphasis
    ) throws {
        var atlas = try makeBaseAtlas()
        for (cell, matrix) in overlay {
            atlas.addTintMatrix(
                .init(sourceColor: sourceColor, matrix: matrix),
                for: cell
            )
        }
        XCTAssertNotNil(
            GlassEffectController.resolvedTintAtlas(
                atlas,
                color: sourceColor.nsColor,
                emphasis: resolvesEmphasis,
                osMajorVersion: 27
            ),
            "the \(resolvesEmphasis) emphasis must resolve this overlay"
        )
        XCTAssertNil(
            GlassEffectController.resolvedTintAtlas(
                atlas,
                color: sourceColor.nsColor,
                emphasis: failsEmphasis,
                osMajorVersion: 27
            ),
            "the \(failsEmphasis) emphasis must fail closed on this overlay"
        )
    }

    private func cells(
        hasMainParticipation: Bool
    ) -> [GlassMaterialStyleAtlas.Cell] {
        [true, false].flatMap { isLight in
            [false, true].map { isClear in
                GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: hasMainParticipation
                )
            }
        }
    }

    private func makeBaseAtlas() throws -> GlassMaterialStyleAtlas {
        let bundledURL = try XCTUnwrap(
            GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 27)
        )
        return try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: Data(contentsOf: bundledURL)
        )
    }

    private func outOfDomainColor() -> GlassMaterialColorValue {
        GlassMaterialColorValue(
            red: 1.4,
            green: -0.4,
            blue: 0.2,
            alpha: 0.6
        )
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
}
