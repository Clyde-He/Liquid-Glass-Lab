import AppKit
import Foundation
import XCTest
@testable import AdjustableGlass

@available(macOS 26.0, *)
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

    private struct WideGamutDocument: Decodable {
        var rows: [WideGamutRow]
    }

    private struct WideGamutRow: Decodable {
        var cell: GlassMaterialStyleAtlas.Cell
        var colorID: String
        var flushMatrix: [Float]?
        var isInCertifiedDomain: Bool
        var sourceColor: GlassMaterialColorValue
    }

    private struct Residual {
        var value: Double
        var colorID: String
        var coefficient: Int
        var fixture: String
    }

    @MainActor
    func testEverySupportedMajorPassesGoldenBackedTintCertification() throws {
        for major in GlassMaterialTintMatrixSynthesizer
            .supportedOSMajorVersions.sorted() {
            try assertGoldenBackedTintCertification(for: major)
        }
    }

    private func assertGoldenBackedTintCertification(for major: Int) throws {
        let directory = "Golden/macOS-\(major)"
        let requiredDocuments = [
            "tint.parameterization.sweep",
            "tint.parameterization.focused-2b",
            "tint.parameterization.hue-2c",
            "tint.sync-resolution",
            "tint.wide-gamut",
        ]
        for documentID in requiredDocuments {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: try documentURL(
                        documentID,
                        directory: directory
                    ).path
                ),
                "Missing required Golden document \(documentID)"
            )
        }

        var worst = Residual(
            value: 0,
            colorID: "",
            coefficient: 0,
            fixture: ""
        )
        var rowCount = 0
        for moduleID in requiredDocuments.prefix(3) {
            let document = try loadSweep(
                moduleID: moduleID,
                directory: directory
            )
            for row in document.rows {
                let synthesized = try XCTUnwrap(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: row.sourceColor,
                        cell: row.cell,
                        osMajorVersion: major
                    ),
                    "No synthesized matrix for \(row.colorID) in \(moduleID)"
                )
                XCTAssertEqual(synthesized.count, row.matrix.count)
                rowCount += 1
                for coefficient in row.matrix.indices {
                    let residual = abs(
                        Double(synthesized[coefficient])
                            - Double(row.matrix[coefficient])
                    )
                    if residual > worst.value {
                        worst = Residual(
                            value: residual,
                            colorID: row.colorID,
                            coefficient: coefficient,
                            fixture: moduleID
                        )
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

        let wide = try loadWideGamutDocument(
            moduleID: "tint.wide-gamut",
            directory: directory
        )
        XCTAssertEqual(wide.rows.count, 408)
        XCTAssertEqual(
            wide.rows.filter { !$0.isInCertifiedDomain }.count,
            288
        )
        for row in wide.rows {
            let reference = try XCTUnwrap(row.flushMatrix)
            let synthesized = try XCTUnwrap(
                GlassMaterialTintMatrixSynthesizer.matrix(
                    for: row.sourceColor,
                    cell: row.cell,
                    osMajorVersion: major
                )
            )
            XCTAssertEqual(synthesized.count, reference.count)
            for coefficient in reference.indices {
                XCTAssertLessThanOrEqual(
                    abs(
                        Double(synthesized[coefficient])
                            - Double(reference[coefficient])
                    ),
                    0.0002,
                    "Wide-gamut residual in \(row.colorID) coefficient \(coefficient)"
                )
            }
        }

        let sync = try loadWideGamutDocument(
            moduleID: "tint.sync-resolution",
            directory: directory
        )
        XCTAssertEqual(
            sync.rows.filter { $0.colorID.hasPrefix("alpha-p3-") }.count,
            80
        )
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

        for moduleID in [
            "tint.parameterization.sweep",
            "tint.parameterization.focused-2b",
            "tint.parameterization.hue-2c",
        ] {
            let document = try loadSweep(moduleID: moduleID)
            for row in document.rows {
                let synthesized = try XCTUnwrap(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: row.sourceColor,
                        cell: row.cell,
                        osMajorVersion: 27
                    ),
                    "No synthesized matrix for \(row.colorID) in \(moduleID)"
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
                        fixture: moduleID
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
    func testMacOS27DisplayP3BoundaryAndHoldoutPassExtendedModelGate()
        throws {
        let document = try loadWideGamutDocument(
            moduleID: "tint.wide-gamut"
        )
        var worst = Residual(
            value: 0,
            colorID: "",
            coefficient: 0,
            fixture: "tint-wide-gamut-model.json"
        )
        var worstHoldout = worst

        for row in document.rows {
            let reference = try XCTUnwrap(
                row.flushMatrix,
                "Missing live matrix for \(row.colorID)"
            )
            let synthesized = try XCTUnwrap(
                GlassMaterialTintMatrixSynthesizer.matrix(
                    for: row.sourceColor,
                    cell: row.cell,
                    osMajorVersion: 27
                ),
                "No synthesized matrix for \(row.colorID)"
            )
            XCTAssertEqual(synthesized.count, reference.count)
            for coefficient in reference.indices {
                let residual = abs(
                    Double(synthesized[coefficient])
                        - Double(reference[coefficient])
                )
                let observation = Residual(
                    value: residual,
                    colorID: row.colorID,
                    coefficient: coefficient,
                    fixture: worst.fixture
                )
                if residual > worst.value { worst = observation }
                if row.colorID.hasPrefix("holdout-p3-"),
                   residual > worstHoldout.value {
                    worstHoldout = observation
                }
            }
        }

        XCTAssertEqual(document.rows.count, 408)
        XCTAssertEqual(
            document.rows.filter { !$0.isInCertifiedDomain }.count,
            288
        )
        XCTAssertLessThanOrEqual(
            worst.value,
            0.000002,
            failureDescription(for: worst)
        )
        XCTAssertLessThanOrEqual(
            worstHoldout.value,
            0.000001,
            "Holdout " + failureDescription(for: worstHoldout)
        )
    }

    @MainActor
    func testMacOS26DisplayP3BoundaryAndHoldoutPassExtendedModelGate()
        throws {
        let document = try loadWideGamutDocument(
            moduleID: "tint.wide-gamut",
            directory: "Golden/macOS-26"
        )
        var worst = Residual(
            value: 0,
            colorID: "",
            coefficient: 0,
            fixture: "Golden/macOS-26/tint-wide-gamut-model.json"
        )
        var worstExtendedChromatic = worst
        var worstHoldout = worst

        for row in document.rows {
            let reference = try XCTUnwrap(
                row.flushMatrix,
                "Missing live matrix for \(row.colorID)"
            )
            let synthesized = try XCTUnwrap(
                GlassMaterialTintMatrixSynthesizer.matrix(
                    for: row.sourceColor,
                    cell: row.cell,
                    osMajorVersion: 26
                ),
                "No synthesized matrix for \(row.colorID)"
            )
            XCTAssertEqual(synthesized.count, reference.count)
            let sourceRGB = [
                row.sourceColor.red,
                row.sourceColor.green,
                row.sourceColor.blue,
            ]
            let chroma = (sourceRGB.max() ?? 0) - (sourceRGB.min() ?? 0)
            for coefficient in reference.indices {
                let residual = abs(
                    Double(synthesized[coefficient])
                        - Double(reference[coefficient])
                )
                let observation = Residual(
                    value: residual,
                    colorID: row.colorID,
                    coefficient: coefficient,
                    fixture: worst.fixture
                )
                if residual > worst.value { worst = observation }
                if !row.isInCertifiedDomain, chroma > 0.00035,
                   residual > worstExtendedChromatic.value {
                    worstExtendedChromatic = observation
                }
                if row.colorID.hasPrefix("holdout-p3-"),
                   residual > worstHoldout.value {
                    worstHoldout = observation
                }
            }
        }

        let chromaticOutsideRows = document.rows.filter { row in
            let sourceRGB = [
                row.sourceColor.red,
                row.sourceColor.green,
                row.sourceColor.blue,
            ]
            return !row.isInCertifiedDomain
                && (sourceRGB.max() ?? 0) - (sourceRGB.min() ?? 0) > 0.00035
        }
        XCTAssertEqual(document.rows.count, 408)
        XCTAssertEqual(
            document.rows.filter { !$0.isInCertifiedDomain }.count,
            288
        )
        XCTAssertEqual(chromaticOutsideRows.count, 280)
        XCTAssertLessThanOrEqual(
            worst.value,
            0.0002,
            failureDescription(for: worst)
        )
        XCTAssertLessThanOrEqual(
            worstExtendedChromatic.value,
            0.000002,
            "Extended chromatic "
                + failureDescription(for: worstExtendedChromatic)
        )
        XCTAssertLessThanOrEqual(
            worstHoldout.value,
            0.000001,
            "Holdout " + failureDescription(for: worstHoldout)
        )
    }

    @MainActor
    func testMacOS27DisplayP3GoldenAlphaSweepOnlyChangesCoefficient18()
        throws {
        let document = try loadWideGamutDocument(
            moduleID: "tint.sync-resolution"
        )
        let alphaRows = document.rows.filter {
            $0.colorID.hasPrefix("alpha-p3-")
        }
        XCTAssertEqual(alphaRows.count, 80)

        for colorFamily in ["p3-c7cd28", "p3-pure-red"] {
            for cell in GlassMaterialStyleAtlas.allTintCells {
                let rows = alphaRows.filter {
                    $0.colorID.contains(colorFamily) && $0.cell == cell
                }
                XCTAssertEqual(rows.count, 5)
                let baseline = try XCTUnwrap(rows.first?.flushMatrix)
                for row in rows {
                    let matrix = try XCTUnwrap(row.flushMatrix)
                    XCTAssertEqual(
                        matrix[18],
                        Float(row.sourceColor.alpha),
                        accuracy: 0.000001
                    )
                    for coefficient in matrix.indices
                    where coefficient != 18 {
                        XCTAssertEqual(
                            matrix[coefficient],
                            baseline[coefficient]
                        )
                    }
                }
            }
        }
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

        for moduleID in [
            "tint.parameterization.sweep",
            "tint.parameterization.focused-2b",
            "tint.parameterization.hue-2c",
        ] {
            let document = try loadSweep(
                moduleID: moduleID,
                directory: "Golden/macOS-26"
            )
            for row in document.rows {
                let synthesized = try XCTUnwrap(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: row.sourceColor,
                        cell: row.cell,
                        osMajorVersion: 26
                    ),
                    "No synthesized matrix for \(row.colorID) in \(moduleID)"
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
                        fixture: moduleID
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
    func testUnsupportedMajorAndUncertifiedExtendedRangeFailClosed() {
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
        let uncertifiedExtended = GlassMaterialColorValue(
            red: 2,
            green: -1,
            blue: 0.3,
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
                    for: uncertifiedExtended,
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
            GlassEffectController.Emphasis.normal,
            .muted,
        ] {
            let resolved = try XCTUnwrap(
                GlassEffectController.resolvedTintAtlas(
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
    func testDisplayP3ColorsUseCertifiedDomainsWithoutClamping()
        throws {
        // The reported #C7CD28 in Display P3, plus two saturated P3 colors.
        // Their extended-sRGB components leave [0, 1], but remain in the
        // independently certified Display P3 domain on macOS 26 and 27.
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
            for osMajorVersion in [26, 27] {
                XCTAssertTrue(
                    GlassMaterialTintMatrixSynthesizer
                        .isWithinCertifiedSynthesisDomain(
                            source,
                            osMajorVersion: osMajorVersion
                        )
                )

                for cell in cells(hasMainParticipation: true) {
                    let matrix = try XCTUnwrap(
                        GlassMaterialTintMatrixSynthesizer.matrix(
                            for: source,
                            cell: cell,
                            osMajorVersion: osMajorVersion
                        )
                    )
                    if cell.isLightAppearance && !cell.isClear {
                        for row in 0..<3 {
                            let bright = matrix[(row * 5)...(row * 5 + 2)]
                                .reduce(matrix[row * 5 + 4], +)
                            XCTAssertEqual(
                                Double(bright),
                                components[row],
                                accuracy: 0.000002
                            )
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testDisplayP3AlphaOnlyChangesCoefficient18() throws {
        let base = NSColor(
            displayP3Red: 1,
            green: 0,
            blue: 0,
            alpha: 1
        )
        let low = try XCTUnwrap(GlassMaterialColorValue(
            base.withAlphaComponent(0.15)
        ))
        let high = try XCTUnwrap(GlassMaterialColorValue(
            base.withAlphaComponent(0.8)
        ))

        for hasMainParticipation in [false, true] {
            for cell in cells(
                hasMainParticipation: hasMainParticipation
            ) {
                let lowMatrix = try XCTUnwrap(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: low,
                        cell: cell,
                        osMajorVersion: 27
                    )
                )
                let highMatrix = try XCTUnwrap(
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: high,
                        cell: cell,
                        osMajorVersion: 27
                    )
                )
                for coefficient in lowMatrix.indices where coefficient != 18 {
                    XCTAssertEqual(
                        lowMatrix[coefficient],
                        highMatrix[coefficient]
                    )
                }
                XCTAssertEqual(lowMatrix[18], 0.15, accuracy: 0.000001)
                XCTAssertEqual(highMatrix[18], 0.8, accuracy: 0.000001)
            }
        }
    }

    @MainActor
    func testControllerResolvesDisplayP3WithoutCachedTintOrHost() throws {
        let catalogURL = try XCTUnwrap(
            GlassMaterialAtlasCatalog.bundledAtlasURL(forMacOSMajor: 27)
        )
        let atlas = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: Data(contentsOf: catalogURL)
        )
        let color = NSColor(
            displayP3Red: 199 / 255.0,
            green: 205 / 255.0,
            blue: 40 / 255.0,
            alpha: 0.8
        )

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
                XCTAssertEqual(
                    resolved.tintMatrix(for: cell, matching: color),
                    expected
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
            GlassEffectController.resolvedTintAtlas(
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
            GlassEffectController.resolvedTintAtlas(
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

    private func documentURL(
        _ moduleID: String,
        directory: String
    ) throws -> URL {
        let files = [
            "tint.parameterization.sweep":
                "tint-parameterization-sweep.json",
            "tint.parameterization.focused-2b":
                "tint-parameterization-focused-phase-2b.json",
            "tint.parameterization.hue-2c":
                "tint-parameterization-hue-phase-2c.json",
            "tint.sync-resolution": "tint-sync-resolution.json",
            "tint.wide-gamut": "tint-wide-gamut-model.json",
        ]
        let file = try XCTUnwrap(
            files[moduleID],
            "Unknown Golden document \(moduleID)"
        )
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryRoot.appendingPathComponent(directory)
            .appendingPathComponent(file)
    }

    private func loadSweep(
        moduleID: String,
        directory: String = "Golden/macOS-27"
    ) throws -> SweepDocument {
        return try JSONDecoder().decode(
            SweepDocument.self,
            from: Data(
                contentsOf: try documentURL(moduleID, directory: directory)
            )
        )
    }

    private func loadWideGamutDocument(
        moduleID: String,
        directory: String = "Golden/macOS-27"
    ) throws -> WideGamutDocument {
        return try JSONDecoder().decode(
            WideGamutDocument.self,
            from: Data(
                contentsOf: try documentURL(moduleID, directory: directory)
            )
        )
    }

    private func failureDescription(for residual: Residual) -> String {
        "Maximum residual \(residual.value) at coefficient "
            + "\(residual.coefficient) for \(residual.colorID) "
            + "in \(residual.fixture)"
    }
}
