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
                cell: darkRegularMainOn
            ),
            .achromatic
        )
        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: chromatic,
                cell: darkRegularMainOn
            ),
            .pastel
        )
        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: chromatic,
                cell: darkClearMainOn
            ),
            .standard
        )
        XCTAssertEqual(
            GlassMaterialTintMatrixSynthesizer.family(
                for: chromatic,
                cell: lightRegularMainOff
            ),
            .neutralSuppression
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

        XCTAssertNil(
            GlassMaterialTintMatrixSynthesizer.matrix(
                for: ordinary,
                cell: cell,
                osMajorVersion: 26
            )
        )
        XCTAssertNil(
            GlassMaterialTintMatrixSynthesizer.matrix(
                for: extended,
                cell: cell,
                osMajorVersion: 27
            )
        )
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
                osMajorVersion: 26
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
                osMajorVersion: 26
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

    private func loadSweep(named name: String) throws -> SweepDocument {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("Golden/macOS-27")
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
