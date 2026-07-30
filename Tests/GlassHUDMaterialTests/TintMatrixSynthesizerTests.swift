import AppKit
import Foundation
import XCTest
@testable import GlassHUDMaterial

final class TintMatrixSynthesizerTests: XCTestCase {
    private struct SweepDocument: Decodable {
        var rows: [SweepRow]
    }

    private struct SweepRow: Decodable {
        var cell: GlassMaterialStyleAtlas.Cell
        var colorID: String
        var matrix: [Float]
        var sourceColor: GlassMaterialColorValue
        var structure: String
    }

    private struct Residual {
        var value: Double
        var colorID: String
        var coefficient: Int
        var fixture: String
    }

    @MainActor
    func testMacOS27GoldenSweepsPassParameterizedMatrixGate() throws {
        var worst = Residual(
            value: 0,
            colorID: "",
            coefficient: 0,
            fixture: ""
        )
        var worstHoldout = worst
        var rowCount = 0

        for name in [
            "tint-parameterization-sweep.json",
            "tint-parameterization-focused-phase-2b.json",
            "tint-parameterization-hue-phase-2c.json",
        ] {
            let document = try loadSweep(named: name)
            for row in document.rows {
                let synthesized = try XCTUnwrap(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: row.sourceColor,
                        cell: row.cell,
                        osMajorVersion: 27
                    ),
                    "No synthesized matrix for \(row.colorID) in \(name)"
                )
                XCTAssertEqual(synthesized.count, row.matrix.count)
                rowCount += 1

                for coefficient in row.matrix.indices {
                    let residual = abs(
                        Double(synthesized[coefficient])
                            - Double(row.matrix[coefficient])
                    )
                    let observation = Residual(
                        value: residual,
                        colorID: row.colorID,
                        coefficient: coefficient,
                        fixture: name
                    )
                    if residual > worst.value { worst = observation }
                    if row.colorID.hasPrefix("rgb-holdout-"),
                       row.structure == "lumaEndpoints",
                       residual > worstHoldout.value {
                        worstHoldout = observation
                    }
                }
            }
        }

        XCTAssertEqual(rowCount, 3_496)
        XCTAssertLessThanOrEqual(
            worst.value,
            0.0002,
            failureDescription(for: worst)
        )
        XCTAssertLessThanOrEqual(
            worstHoldout.value,
            0.0000005,
            "Holdout " + failureDescription(for: worstHoldout)
        )
    }

    @MainActor
    func testMacOS26GoldenSweepsPassParameterizedMatrixGate() throws {
        var worst = Residual(
            value: 0,
            colorID: "",
            coefficient: 0,
            fixture: ""
        )
        var worstChromaticHoldout = worst
        var worstGrayHoldout = worst
        var rowCount = 0

        for name in [
            "tint-parameterization-sweep.json",
            "tint-parameterization-focused-phase-2b.json",
            "tint-parameterization-hue-phase-2c.json",
        ] {
            let document = try loadSweep(
                named: name,
                directory: "Golden/macOS-26"
            )
            for row in document.rows {
                let synthesized = try XCTUnwrap(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: row.sourceColor,
                        cell: row.cell,
                        osMajorVersion: 26
                    ),
                    "No synthesized matrix for \(row.colorID) in \(name)"
                )
                XCTAssertEqual(synthesized.count, row.matrix.count)
                rowCount += 1

                for coefficient in row.matrix.indices {
                    let residual = abs(
                        Double(synthesized[coefficient])
                            - Double(row.matrix[coefficient])
                    )
                    let observation = Residual(
                        value: residual,
                        colorID: row.colorID,
                        coefficient: coefficient,
                        fixture: name
                    )
                    if residual > worst.value { worst = observation }
                    if row.colorID.hasPrefix("rgb-holdout-"),
                       residual > worstChromaticHoldout.value {
                        worstChromaticHoldout = observation
                    }
                    if row.colorID.hasPrefix("gray-holdout-"),
                       residual > worstGrayHoldout.value {
                        worstGrayHoldout = observation
                    }
                }
            }
        }

        XCTAssertEqual(rowCount, 3_496)
        XCTAssertLessThanOrEqual(
            worst.value,
            0.0002,
            failureDescription(for: worst)
        )
        // The chromatic transforms were fitted on macOS 27 data only, so the
        // entire 26 dataset is out-of-sample; the reserved holdouts must
        // still be float-exact, and the 26 achromatic family must hold its
        // fitted-noise bound on the gray holdouts.
        XCTAssertLessThanOrEqual(
            worstChromaticHoldout.value,
            0.0000005,
            "Chromatic holdout " + failureDescription(
                for: worstChromaticHoldout
            )
        )
        XCTAssertLessThanOrEqual(
            worstGrayHoldout.value,
            0.0001,
            "Gray holdout " + failureDescription(for: worstGrayHoldout)
        )
    }

    @MainActor
    func testContextFamilyIsSemanticAtNearWhiteBoundary() {
        let achromatic = [1.0, 0.999785, 0.9997]
        let chromatic = [1.0, 0.9997133333333333, 0.9996]
        let darkRegularMainOn = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: false,
            isClear: false,
            hasMainParticipation: true
        )
        let lightRegularMainOff = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: true,
            isClear: false,
            hasMainParticipation: false
        )
        let darkClearMainOn = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: false,
            isClear: true,
            hasMainParticipation: true
        )

        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: achromatic,
                cell: darkRegularMainOn,
                osMajorVersion: 27
            ),
            .achromatic
        )
        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: chromatic,
                cell: darkRegularMainOn,
                osMajorVersion: 27
            ),
            .pastel
        )
        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: chromatic,
                cell: darkClearMainOn,
                osMajorVersion: 27
            ),
            .standard
        )
        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: chromatic,
                cell: lightRegularMainOff,
                osMajorVersion: 27
            ),
            .neutralSuppression
        )
    }

    @MainActor
    func testMacOS26SelectionTableDiffersFromMacOS27() {
        let chromatic = [0.9, 0.3, 0.2]
        let achromatic = [0.5, 0.5, 0.5]
        let darkClearMainOn = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: false,
            isClear: true,
            hasMainParticipation: true
        )
        let lightClearMainOff = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: true,
            isClear: true,
            hasMainParticipation: false
        )
        let lightRegularMainOn = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: true,
            isClear: false,
            hasMainParticipation: true
        )

        // Dark Clear Main-On: pastel on 26, standard on 27.
        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: chromatic,
                cell: darkClearMainOn,
                osMajorVersion: 26
            ),
            .pastel
        )
        // Clear Main-Off: suppressed on 26, standard (= Main-On) on 27.
        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: chromatic,
                cell: lightClearMainOff,
                osMajorVersion: 26
            ),
            .neutralSuppression
        )
        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: chromatic,
                cell: lightClearMainOff,
                osMajorVersion: 27
            ),
            .standard
        )
        // Achromatic Main-On: saturation-boost family on 26 only.
        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: achromatic,
                cell: lightRegularMainOn,
                osMajorVersion: 26
            ),
            .achromaticSaturationBoost
        )
    }

    @MainActor
    func testUnsupportedMajorAndExtendedRangeFailClosed() {
        let cell = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: true,
            isClear: false,
            hasMainParticipation: true
        )
        let ordinary = GlassMaterialColorValue(
            red: 0.8,
            green: 0.3,
            blue: 0.1,
            alpha: 0.5
        )
        let extended = GlassMaterialColorValue(
            red: 1.1,
            green: 0.3,
            blue: 0.1,
            alpha: 0.5
        )

        for unsupportedMajor in [25, 28] {
            XCTAssertNil(
                GlassMaterialTintMatrixSynthesizer.matrix(
                    for: ordinary,
                    cell: cell,
                    osMajorVersion: unsupportedMajor
                )
            )
        }
        for certifiedMajor in [26, 27] {
            XCTAssertNotNil(
                GlassMaterialTintMatrixSynthesizer.matrix(
                    for: ordinary,
                    cell: cell,
                    osMajorVersion: certifiedMajor
                )
            )
            XCTAssertNil(
                GlassMaterialTintMatrixSynthesizer.matrix(
                    for: extended,
                    cell: cell,
                    osMajorVersion: certifiedMajor
                )
            )
        }
    }

    @MainActor
    func testControllerUsesEphemeralMacOS27SynthesisForBothEmphases() throws {
        let catalogURL = try XCTUnwrap(
            GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 27)
        )
        var atlas = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: Data(contentsOf: catalogURL)
        )
        let color = NSColor(
            srgbRed: 0.08,
            green: 0.78,
            blue: 0.71,
            alpha: 0.63
        )
        let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
        let legacyMatrix = [Float](repeating: 0.25, count: 20)

        for hasMainParticipation in [false, true] {
            for cell in cells(
                hasMainParticipation: hasMainParticipation
            ) {
                atlas.addTintMatrix(
                    .init(
                        sourceColor: sourceColor,
                        matrix: legacyMatrix
                    ),
                    for: cell
                )
            }
        }

        for emphasis in [
            GlassHUDMaterialController.Emphasis.normal,
            .muted,
        ] {
            let resolved = try XCTUnwrap(
                GlassHUDMaterialController.resolvedTintAtlas(
                    atlas,
                    color: color,
                    emphasis: emphasis,
                    osMajorVersion: 27
                )
            )
            let hasMainParticipation = emphasis == .normal
            for cell in cells(
                hasMainParticipation: hasMainParticipation
            ) {
                let expected = try XCTUnwrap(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: color,
                        cell: cell,
                        osMajorVersion: 27
                    )
                )
                let actual = try XCTUnwrap(
                    resolved.tintMatrix(for: cell, matching: color)
                )
                XCTAssertEqual(actual, expected)
                XCTAssertNotEqual(actual, legacyMatrix)
            }
        }

        // The controller resolves into a value-semantic copy. The Provider's
        // cache remains untouched and cannot win over synthesis on macOS 27.
        for hasMainParticipation in [false, true] {
            for cell in cells(
                hasMainParticipation: hasMainParticipation
            ) {
                XCTAssertEqual(
                    atlas.tintMatrix(for: cell, matching: color),
                    legacyMatrix
                )
            }
        }
    }

    @MainActor
    func testWiderGamutColorsLeaveTheCertifiedSynthesisDomain() throws {
        // The reported #C7CD28 in Display P3, plus two saturated P3 colors.
        // Converted to extended sRGB these carry components outside [0, 1],
        // where the fitted closed form is wrong by 0.24 to 0.57 (see
        // Golden/macOS-26/tint-sync-resolution.json). Synthesis must refuse
        // them on every certified major so the commit resolver takes over.
        let cell = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: true,
            isClear: false,
            hasMainParticipation: true
        )
        let wideGamut = [
            NSColor(
                displayP3Red: 199 / 255.0,
                green: 205 / 255.0,
                blue: 40 / 255.0,
                alpha: 0.8
            ),
            NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 0.8),
            NSColor(displayP3Red: 0.1, green: 0.95, blue: 0.2, alpha: 0.8),
        ]
        for color in wideGamut {
            let source = try XCTUnwrap(GlassMaterialColorValue(color))
            let components = [source.red, source.green, source.blue]
            XCTAssertFalse(
                components.allSatisfy { $0 >= 0 && $0 <= 1 },
                "expected an out-of-domain component in \(components)"
            )
            for major in [26, 27] {
                XCTAssertNil(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: source,
                        cell: cell,
                        osMajorVersion: major
                    )
                )
            }
        }
    }

    @MainActor
    func testControllerRequiresCompleteCapturedFallbackOnUnsupportedMajor()
        throws {
        let catalogURL = try XCTUnwrap(
            GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 27)
        )
        var atlas = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: Data(contentsOf: catalogURL)
        )
        let color = NSColor(
            srgbRed: 0.92,
            green: 0.18,
            blue: 0.38,
            alpha: 0.8
        )
        let sourceColor = try XCTUnwrap(GlassMaterialColorValue(color))
        let capturedMatrix = [Float](repeating: 0.5, count: 20)
        let requiredCells = cells(hasMainParticipation: true)

        for cell in requiredCells.dropLast() {
            atlas.addTintMatrix(
                .init(
                    sourceColor: sourceColor,
                    matrix: capturedMatrix
                ),
                for: cell
            )
        }
        XCTAssertNil(
            GlassHUDMaterialController.resolvedTintAtlas(
                atlas,
                color: color,
                emphasis: .normal,
                osMajorVersion: 28
            )
        )

        atlas.addTintMatrix(
            .init(
                sourceColor: sourceColor,
                matrix: capturedMatrix
            ),
            for: try XCTUnwrap(requiredCells.last)
        )
        let resolved = try XCTUnwrap(
            GlassHUDMaterialController.resolvedTintAtlas(
                atlas,
                color: color,
                emphasis: .normal,
                osMajorVersion: 28
            )
        )
        for cell in requiredCells {
            XCTAssertEqual(
                resolved.tintMatrix(for: cell, matching: color),
                capturedMatrix
            )
        }
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

    private func loadSweep(
        named name: String,
        directory: String = "Golden/macOS-27"
    ) throws -> SweepDocument {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent(directory)
            .appendingPathComponent(name)
        return try JSONDecoder().decode(
            SweepDocument.self,
            from: Data(contentsOf: url)
        )
    }

    private func failureDescription(for residual: Residual) -> String {
        "Maximum residual \(residual.value) at coefficient "
            + "\(residual.coefficient) for \(residual.colorID) "
            + "in \(residual.fixture)"
    }
}
