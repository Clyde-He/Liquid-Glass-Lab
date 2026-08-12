//
//  GlassLabTintParameterizationSweep.swift
//  LiquidGlassLab
//
//  Phase 2 of the existing Tint Study: a research-only, checkpointed color
//  parameterization sweep. One active host plus one nonparticipating witness
//  owns eight long-lived probes while a deterministic color plan changes
//  underneath them. This deliberately does not call the product's per-color
//  capture path: no runtime cache is mutated and no frozen consumer transaction
//  is repeated for every research color.
//

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GlassLabTintSweepColor: Codable, Hashable, Sendable {
    var id: String
    var label: String
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    @MainActor
    var nsColor: NSColor {
        NSColor(
            colorSpace: .extendedSRGB,
            components: [red, green, blue, alpha].map { CGFloat($0) },
            count: 4
        )
    }
}

struct GlassLabTintSweepCell: Codable, Hashable, Sendable {
    var isLightAppearance: Bool
    var isClear: Bool
    var hasMainParticipation: Bool

    init(_ cell: GlassMaterialStyleAtlas.Cell) {
        isLightAppearance = cell.isLightAppearance
        isClear = cell.isClear
        hasMainParticipation = cell.hasMainParticipation
    }

    var atlasCell: GlassMaterialStyleAtlas.Cell {
        GlassMaterialStyleAtlas.Cell(
            isLightAppearance: isLightAppearance,
            isClear: isClear,
            hasMainParticipation: hasMainParticipation
        )
    }

    var label: String {
        (isLightAppearance ? "Light" : "Dark")
            + " · " + (isClear ? "Clear" : "Regular")
            + " · Main-" + (hasMainParticipation ? "On" : "Off")
    }
}

enum GlassLabTintMatrixStructure: String, Codable, Sendable {
    case lumaEndpoints
    case neutralSuppression
    case achromaticChannelAffine
    case unclassified
}

struct GlassLabTintSweepRow: Codable, Hashable, Sendable {
    var colorID: String
    var sourceColor: GlassMaterialColorValue
    var cell: GlassLabTintSweepCell
    var matrix: [Float]
    var structure: GlassLabTintMatrixStructure
    var maximumStructureResidual: Double
    var lumaEndpointResidual: Double?
    var neutralSuppressionResidual: Double?
    var achromaticChannelAffineResidual: Double?
}

struct GlassLabTintSweepPlan: Codable, Equatable, Sendable {
    var id: String
    var referenceWidth: Double
    var referenceShortSide: Double
    var consecutiveStableReads: Int
    var colors: [GlassLabTintSweepColor]

    static let fullGridV1 = GlassLabTintSweepPlan(
        id: "tint-parameterization-full-grid-v1",
        referenceWidth: 480,
        referenceShortSide: 200,
        consecutiveStableReads: 2,
        colors: makeFullGridColors()
    )

    static let focusedPhase2b = GlassLabTintSweepPlan(
        id: "tint-parameterization-focused-phase-2b",
        referenceWidth: 480,
        referenceShortSide: 200,
        consecutiveStableReads: 2,
        colors: makeFocusedPhase2bColors()
    )

    static let hueFractionPhase2c = GlassLabTintSweepPlan(
        id: "tint-parameterization-hue-fraction-phase-2c",
        referenceWidth: 480,
        referenceShortSide: 200,
        consecutiveStableReads: 2,
        colors: makeHueFractionPhase2cColors()
    )

    private static func makeFullGridColors() -> [GlassLabTintSweepColor] {
        var colors: [GlassLabTintSweepColor] = []

        // The primary fitting grid: 12 hues × 4 saturations × 3 brightnesses.
        // It intentionally includes gamut-edge colors (S=1, V=1).
        for hueIndex in 0..<12 {
            let hue = Double(hueIndex) / 12
            for saturation in [0.25, 0.5, 0.75, 1.0] {
                for brightness in [0.25, 0.625, 1.0] {
                    colors.append(hsvColor(
                        id: String(
                            format: "grid-h%03d-s%03d-v%03d",
                            hueIndex * 30,
                            Int((saturation * 1000).rounded()),
                            Int((brightness * 1000).rounded())
                        ),
                        label: String(
                            format: "Grid H%03d S%.3f V%.3f",
                            hueIndex * 30,
                            saturation,
                            brightness
                        ),
                        hue: hue,
                        saturation: saturation,
                        brightness: brightness,
                        alpha: 0.5
                    ))
                }
            }
        }

        // Achromatic samples keep hue-space models honest at S=0.
        for value in [0.0, 0.125, 0.25, 0.5, 0.75, 1.0] {
            colors.append(GlassLabTintSweepColor(
                id: "gray-\(componentLabel(value))",
                label: String(format: "Gray %.3f", value),
                red: value,
                green: value,
                blue: value,
                alpha: 0.5
            ))
        }

        // A deliberately near-black hue ring. The main grid starts at V=.25,
        // which is not dark enough to constrain the standard dark endpoint.
        for hueIndex in 0..<12 {
            let hue = Double(hueIndex) / 12
            colors.append(hsvColor(
                id: String(format: "very-dark-h%03d", hueIndex * 30),
                label: String(format: "Very Dark H%03d", hueIndex * 30),
                hue: hue,
                saturation: 1,
                brightness: 0.05,
                alpha: 0.5
            ))
        }

        // Preserve the two historical evidence colors as exact repeat anchors.
        colors.append(GlassLabTintSweepColor(
            id: "known-coral",
            label: "Known Coral",
            red: 0.92,
            green: 0.18,
            blue: 0.38,
            alpha: 0.5
        ))
        colors.append(GlassLabTintSweepColor(
            id: "known-cyan",
            label: "Known Cyan",
            red: 0.12,
            green: 0.72,
            blue: 0.94,
            alpha: 0.5
        ))

        // Fixed-RGB alpha sweep. It verifies that changing alpha touches only
        // coefficient 18 and leaves all endpoint coefficients invariant.
        for alpha in [0.1, 0.25, 0.5, 0.6, 0.75, 1.0] {
            colors.append(GlassLabTintSweepColor(
                id: "salmon-a\(componentLabel(alpha))",
                label: String(format: "Salmon α %.2f", alpha),
                red: 1,
                green: 0.45,
                blue: 0.35,
                alpha: alpha
            ))
        }
        return colors
    }

    private static func makeFocusedPhase2bColors()
        -> [GlassLabTintSweepColor] {
        var colors: [GlassLabTintSweepColor] = []
        let hues = [17.0, 137.0]

        // The full grid found a separate high-brightness branch. Sample that
        // region densely at two off-axis hues without repeating the 12-hue
        // symmetry proof from v1.
        for hueDegrees in hues {
            for saturation in [0.1, 0.25, 0.5, 0.75, 1.0] {
                for brightness in [
                    0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 0.98, 1.0,
                ] {
                    colors.append(hsvColor(
                        id: String(
                            format: "high-h%03d-s%03d-v%03d",
                            Int(hueDegrees),
                            Int((saturation * 1000).rounded()),
                            Int((brightness * 1000).rounded())
                        ),
                        label: String(
                            format: "High H%03d S%.3f V%.3f",
                            Int(hueDegrees),
                            saturation,
                            brightness
                        ),
                        hue: hueDegrees / 360,
                        saturation: saturation,
                        brightness: brightness,
                        alpha: 0.5
                    ))
                }
            }
        }

        // Locate the transition between the exact achromatic family and the
        // hue-carrying endpoint family near S=0.
        for hueDegrees in hues {
            for saturation in [0.001, 0.005, 0.01, 0.025, 0.05] {
                for brightness in [0.25, 0.625, 0.85, 1.0] {
                    colors.append(hsvColor(
                        id: String(
                            format: "low-s-h%03d-s%03d-v%03d",
                            Int(hueDegrees),
                            Int((saturation * 1000).rounded()),
                            Int((brightness * 1000).rounded())
                        ),
                        label: String(
                            format: "Low-S H%03d S%.3f V%.3f",
                            Int(hueDegrees),
                            saturation,
                            brightness
                        ),
                        hue: hueDegrees / 360,
                        saturation: saturation,
                        brightness: brightness,
                        alpha: 0.5
                    ))
                }
            }
        }

        // Held-out gray values validate the closed-form achromatic transform;
        // none appeared in full-grid-v1.
        for value in [0.0625, 0.1875, 0.375, 0.625, 0.875] {
            colors.append(GlassLabTintSweepColor(
                id: "gray-holdout-\(componentLabel(value))",
                label: String(format: "Gray Holdout %.4f", value),
                red: value,
                green: value,
                blue: value,
                alpha: 0.5
            ))
        }

        // Independent RGB holdouts are excluded from model fitting and remain
        // available for end-to-end interpolation error checks.
        let holdouts: [(String, Double, Double, Double)] = [
            ("rose", 0.83, 0.31, 0.57),
            ("green", 0.34, 0.82, 0.29),
            ("blue", 0.19, 0.47, 0.88),
            ("amber", 0.96, 0.68, 0.12),
            ("violet", 0.62, 0.21, 0.91),
            ("teal", 0.08, 0.78, 0.71),
        ]
        for (name, red, green, blue) in holdouts {
            colors.append(GlassLabTintSweepColor(
                id: "rgb-holdout-\(name)",
                label: "RGB Holdout \(name.capitalized)",
                red: red,
                green: green,
                blue: blue,
                alpha: 0.5
            ))
        }
        return colors
    }

    private static func makeHueFractionPhase2cColors()
        -> [GlassLabTintSweepColor] {
        var colors: [GlassLabTintSweepColor] = []

        // Together with Phase 2b's H17 slice, these positions provide
        // normalized within-sector hue fractions 0, .283, .5, .75, and 1 at
        // every high-brightness S/V coordinate. H0/H30/H60 at V=1 also repeat
        // full-grid anchors, so cross-session agreement is measurable.
        for hueDegrees in [0.0, 30.0, 45.0, 60.0] {
            for saturation in [0.25, 0.5, 0.75, 1.0] {
                for brightness in [
                    0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 0.98, 1.0,
                ] {
                    colors.append(hsvColor(
                        id: String(
                            format: "sector-h%03d-s%03d-v%03d",
                            Int(hueDegrees),
                            Int((saturation * 1000).rounded()),
                            Int((brightness * 1000).rounded())
                        ),
                        label: String(
                            format: "Sector H%03d S%.3f V%.3f",
                            Int(hueDegrees),
                            saturation,
                            brightness
                        ),
                        hue: hueDegrees / 360,
                        saturation: saturation,
                        brightness: brightness,
                        alpha: 0.5
                    ))
                }
            }
        }

        // Phase 2b bracketed the achromatic switch between absolute chroma
        // .00025 and .000625. Probe the same four chroma values at two
        // brightnesses to distinguish an absolute threshold from an HSV
        // saturation threshold.
        for brightness in [0.5, 1.0] {
            for chroma in [0.0003, 0.0004, 0.0005, 0.0006] {
                let saturation = chroma / brightness
                colors.append(hsvColor(
                    id: String(
                        format: "boundary-c%04d-v%04d",
                        Int((chroma * 1_000_000).rounded()),
                        Int((brightness * 1000).rounded())
                    ),
                    label: String(
                        format: "Boundary C%.4f V%.3f",
                        chroma,
                        brightness
                    ),
                    hue: 17.0 / 360,
                    saturation: saturation,
                    brightness: brightness,
                    alpha: 0.5
                ))
            }
        }

        precondition(colors.count == 136)
        precondition(Set(colors.map(\.id)).count == colors.count)
        return colors
    }

    private static func hsvColor(
        id: String,
        label: String,
        hue: Double,
        saturation: Double,
        brightness: Double,
        alpha: Double
    ) -> GlassLabTintSweepColor {
        let sector = (hue - floor(hue)) * 6
        let index = Int(floor(sector)) % 6
        let fraction = sector - floor(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        let rgb: (Double, Double, Double) = switch index {
        case 0: (brightness, t, p)
        case 1: (q, brightness, p)
        case 2: (p, brightness, t)
        case 3: (p, q, brightness)
        case 4: (t, p, brightness)
        default: (brightness, p, q)
        }
        return GlassLabTintSweepColor(
            id: id,
            label: label,
            red: rgb.0,
            green: rgb.1,
            blue: rgb.2,
            alpha: alpha
        )
    }

    private static func componentLabel(_ value: Double) -> String {
        String(format: "%03d", Int((value * 1000).rounded()))
    }
}

struct GlassLabTintParameterizationSweepDocument: Codable, Sendable {
    struct Environment: Codable, Equatable, Sendable {
        var osMajorVersion: Int
        var displaySignature: String
        var atlasSchemaVersion: Int
    }

    var formatVersion: Int
    var capturedAt: String
    var operatingSystem: String
    var environment: Environment
    var plan: GlassLabTintSweepPlan
    var complete: Bool
    var completedColorCount: Int
    var rows: [GlassLabTintSweepRow]
    var failure: String?

    var unclassifiedRowCount: Int {
        rows.lazy.filter { $0.structure == .unclassified }.count
    }
}

enum GlassLabTintSweepError: LocalizedError {
    case noHostWindow
    case probeHostUnavailable
    case hostNotParticipating
    case witnessUnavailable
    case witnessParticipated
    case invalidExistingDocument(String)
    case colorFailed(String)
    case invalidMatrix(String)
    case incomplete(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .noHostWindow:
            "No active control window is available for the Main-On probes."
        case .probeHostUnavailable:
            "The supported in-window probe host is not attached."
        case .hostNotParticipating:
            "Keep the app active and the control window main/key during capture."
        case .witnessUnavailable:
            "The Main-Off witness window could not be prepared."
        case .witnessParticipated:
            "The Main-Off witness unexpectedly became main or key."
        case let .invalidExistingDocument(reason):
            "The existing checkpoint cannot be resumed: \(reason)"
        case let .colorFailed(color):
            "Tint never produced eight stable paired matrices for \(color)."
        case let .invalidMatrix(reason):
            "Tint capture validation failed: \(reason)"
        case let .incomplete(expected, actual):
            "Tint sweep is incomplete: expected \(expected) rows, found \(actual)."
        }
    }
}

enum GlassLabTintMatrixGate {
    private static let luma = [0.2126, 0.7152, 0.0722]
    private static let tolerance = 0.0002

    struct Result {
        var structure: GlassLabTintMatrixStructure
        var maximumResidual: Double
        var lumaEndpointResidual: Double
        var neutralSuppressionResidual: Double
        var achromaticChannelAffineResidual: Double
    }

    static func validate(
        _ tint: GlassMaterialStyleAtlas.TintMatrix,
        expectedColor: GlassLabTintSweepColor,
        cell: GlassMaterialStyleAtlas.Cell
    ) throws -> Result {
        let matrix = tint.matrix.map(Double.init)
        guard matrix.count == 20, matrix.allSatisfy(\.isFinite) else {
            throw GlassLabTintSweepError.invalidMatrix(
                "\(expectedColor.id) · \(GlassLabTintSweepCell(cell).label) "
                    + "does not contain 20 finite coefficients"
            )
        }
        let expected = [expectedColor.red, expectedColor.green, expectedColor.blue]
        let actual = [
            tint.sourceColor.red,
            tint.sourceColor.green,
            tint.sourceColor.blue,
        ]
        let colorResidual = zip(expected, actual).map {
            abs($0 - $1)
        }.max() ?? .infinity
        let alphaResidual = abs(tint.sourceColor.alpha - expectedColor.alpha)
        guard colorResidual <= tolerance, alphaResidual <= tolerance else {
            throw GlassLabTintSweepError.invalidMatrix(
                "\(expectedColor.id) source-color readback differs from request"
            )
        }

        let alphaRowResidual = [
            abs(matrix[15]),
            abs(matrix[16]),
            abs(matrix[17]),
            abs(matrix[18] - expectedColor.alpha),
            abs(matrix[19]),
            abs(matrix[3]),
            abs(matrix[8]),
            abs(matrix[13]),
        ].max() ?? .infinity
        guard alphaRowResidual <= tolerance else {
            throw GlassLabTintSweepError.invalidMatrix(
                "\(expectedColor.id) · \(GlassLabTintSweepCell(cell).label) "
                    + "violates the alpha-row contract "
                    + "(residual \(alphaRowResidual))"
            )
        }

        let rankOneResidual = lumaEndpointResidual(matrix)
        let neutralResidual = neutralSuppressionResidual(
            matrix,
            isLightAppearance: cell.isLightAppearance
        )
        let achromaticResidual = achromaticChannelAffineResidual(matrix)
        if rankOneResidual <= tolerance {
            return Result(
                structure: .lumaEndpoints,
                maximumResidual: max(rankOneResidual, alphaRowResidual),
                lumaEndpointResidual: rankOneResidual,
                neutralSuppressionResidual: neutralResidual,
                achromaticChannelAffineResidual: achromaticResidual
            )
        }
        if neutralResidual <= tolerance {
            return Result(
                structure: .neutralSuppression,
                maximumResidual: max(neutralResidual, alphaRowResidual),
                lumaEndpointResidual: rankOneResidual,
                neutralSuppressionResidual: neutralResidual,
                achromaticChannelAffineResidual: achromaticResidual
            )
        }
        if achromaticResidual <= tolerance {
            return Result(
                structure: .achromaticChannelAffine,
                maximumResidual: max(achromaticResidual, alphaRowResidual),
                lumaEndpointResidual: rankOneResidual,
                neutralSuppressionResidual: neutralResidual,
                achromaticChannelAffineResidual: achromaticResidual
            )
        }
        return Result(
            structure: .unclassified,
            maximumResidual:
                max(
                    min(
                        rankOneResidual,
                        min(neutralResidual, achromaticResidual)
                    ),
                    alphaRowResidual
                ),
            lumaEndpointResidual: rankOneResidual,
            neutralSuppressionResidual: neutralResidual,
            achromaticChannelAffineResidual: achromaticResidual
        )
    }

    private static func lumaEndpointResidual(_ matrix: [Double]) -> Double {
        let denominator = luma.reduce(0) { $0 + $1 * $1 }
        var maximum = 0.0
        for row in 0..<3 {
            let coefficients = Array(matrix[(row * 5)..<(row * 5 + 3)])
            let scale = zip(coefficients, luma).reduce(0) {
                $0 + $1.0 * $1.1
            } / denominator
            for (coefficient, weight) in zip(coefficients, luma) {
                maximum = max(maximum, abs(coefficient - scale * weight))
            }
        }
        return maximum
    }

    private static func neutralSuppressionResidual(
        _ matrix: [Double],
        isLightAppearance: Bool
    ) -> Double {
        let bias = isLightAppearance ? -0.1 : 0.1
        var maximum = 0.0
        for row in 0..<3 {
            for column in 0..<3 {
                let expected = (row == column ? 0.7 : 0) + 0.3 * luma[column]
                maximum = max(
                    maximum,
                    abs(matrix[row * 5 + column] - expected)
                )
            }
            maximum = max(maximum, abs(matrix[row * 5 + 4] - bias))
        }
        return maximum
    }

    private static func achromaticChannelAffineResidual(
        _ matrix: [Double]
    ) -> Double {
        let diagonal = (matrix[0] + matrix[6] + matrix[12]) / 3
        let bias = (matrix[4] + matrix[9] + matrix[14]) / 3
        var maximum = 0.0
        for row in 0..<3 {
            for column in 0..<3 {
                let expected = row == column ? diagonal : 0
                maximum = max(
                    maximum,
                    abs(matrix[row * 5 + column] - expected)
                )
            }
            maximum = max(maximum, abs(matrix[row * 5 + 4] - bias))
        }
        return maximum
    }
}

private final class GlassLabTintSweepWitnessWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class GlassLabTintSweepCaptureSession {
    private struct ProbePair {
        var mainOnCell: GlassMaterialStyleAtlas.Cell
        var mainOn: NSGlassEffectView
        var mainOff: NSGlassEffectView
    }

    private struct StablePair: Equatable {
        var mainOn: GlassMaterialStyleAtlas.TintMatrix
        var mainOff: GlassMaterialStyleAtlas.TintMatrix
    }

    private weak var hostWindow: NSWindow?
    private weak var mainProbeHost: NSView?
    private let plan: GlassLabTintSweepPlan
    private var mainContainer: NSView?
    private var witnessWindow: GlassLabTintSweepWitnessWindow?
    private var witnessContainer: NSView?

    init(
        hostWindow: NSWindow,
        mainProbeHost: NSView,
        plan: GlassLabTintSweepPlan
    ) {
        self.hostWindow = hostWindow
        self.mainProbeHost = mainProbeHost
        self.plan = plan
    }

    func capture(
        colors: [GlassLabTintSweepColor],
        onColor: @MainActor (
            _ color: GlassLabTintSweepColor,
            _ rows: [GlassLabTintSweepRow]
        ) async throws -> Void
    ) async throws {
        guard let hostWindow else {
            throw GlassLabTintSweepError.noHostWindow
        }
        guard let mainProbeHost, mainProbeHost.window === hostWindow else {
            throw GlassLabTintSweepError.probeHostUnavailable
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        hostWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        guard hostParticipates else {
            throw GlassLabTintSweepError.hostNotParticipating
        }

        let mainContainer = makeClippedContainer()
        mainProbeHost.addSubview(mainContainer)
        self.mainContainer = mainContainer
        guard prepareWitnessWindow(), let witnessContainer else {
            tearDown()
            throw GlassLabTintSweepError.witnessUnavailable
        }
        let pairs = makeProbePairs(
            mainContainer: mainContainer,
            witnessContainer: witnessContainer
        )
        defer {
            pairs.forEach {
                $0.mainOn.removeFromSuperview()
                $0.mainOff.removeFromSuperview()
            }
            tearDown()
        }

        mainProbeHost.layoutSubtreeIfNeeded()
        witnessWindow?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        guard hostParticipates, witnessIsMainOff else {
            throw GlassLabTintSweepError.witnessParticipated
        }

        for color in colors {
            try Task.checkCancellation()
            guard hostParticipates else {
                throw GlassLabTintSweepError.hostNotParticipating
            }
            guard witnessIsMainOff else {
                throw GlassLabTintSweepError.witnessParticipated
            }

            for pair in pairs {
                pair.mainOn.tintColor = nil
                pair.mainOff.tintColor = nil
            }
            mainProbeHost.layoutSubtreeIfNeeded()
            witnessWindow?.contentView?.layoutSubtreeIfNeeded()
            for pair in pairs {
                pair.mainOn.tintColor = color.nsColor
                pair.mainOff.tintColor = color.nsColor
            }
            mainProbeHost.layoutSubtreeIfNeeded()
            witnessWindow?.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(350))

            var previous: [GlassMaterialStyleAtlas.Cell: StablePair] = [:]
            var stableCounts: [GlassMaterialStyleAtlas.Cell: Int] = [:]
            var accepted: [GlassMaterialStyleAtlas.Cell: StablePair] = [:]
            var validationFailures:
                [GlassMaterialStyleAtlas.Cell: Error] = [:]

            for _ in 0..<24 where accepted.count < pairs.count {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                guard hostParticipates else {
                    throw GlassLabTintSweepError.hostNotParticipating
                }
                guard witnessIsMainOff else {
                    throw GlassLabTintSweepError.witnessParticipated
                }

                for pair in pairs where accepted[pair.mainOnCell] == nil {
                    let mainOffCell = Self.mainOffCell(for: pair.mainOnCell)
                    guard let mainOnStyle = GlassMaterialStyleSample.capture(
                        from: pair.mainOn
                    ), let mainOffStyle = GlassMaterialStyleSample.capture(
                        from: pair.mainOff
                    ), GlassMaterialStyleAtlas.verifiesMainOn(
                        mainOnStyle,
                        against: mainOffStyle
                    ), let mainOnMatrix =
                        GlassMaterialStyleAtlas.captureTintMatrix(
                            from: pair.mainOn
                        ), let mainOffMatrix =
                        GlassMaterialStyleAtlas.captureTintMatrix(
                            from: pair.mainOff
                        )
                    else {
                        previous[pair.mainOnCell] = nil
                        stableCounts[pair.mainOnCell] = 0
                        continue
                    }
                    do {
                        _ = try GlassLabTintMatrixGate.validate(
                            mainOnMatrix,
                            expectedColor: color,
                            cell: pair.mainOnCell
                        )
                        _ = try GlassLabTintMatrixGate.validate(
                            mainOffMatrix,
                            expectedColor: color,
                            cell: mainOffCell
                        )
                    } catch {
                        validationFailures[pair.mainOnCell] = error
                        previous[pair.mainOnCell] = nil
                        stableCounts[pair.mainOnCell] = 0
                        continue
                    }
                    validationFailures[pair.mainOnCell] = nil

                    let current = StablePair(
                        mainOn: mainOnMatrix,
                        mainOff: mainOffMatrix
                    )
                    if previous[pair.mainOnCell] == current {
                        let count = (stableCounts[pair.mainOnCell] ?? 0) + 1
                        stableCounts[pair.mainOnCell] = count
                        if count >= plan.consecutiveStableReads {
                            accepted[pair.mainOnCell] = current
                        }
                    } else {
                        previous[pair.mainOnCell] = current
                        stableCounts[pair.mainOnCell] = 0
                    }
                }
            }

            guard accepted.count == pairs.count else {
                if let rejected = pairs.first(where: {
                    accepted[$0.mainOnCell] == nil
                        && validationFailures[$0.mainOnCell] != nil
                }), let validationFailure =
                    validationFailures[rejected.mainOnCell] {
                    throw validationFailure
                }
                throw GlassLabTintSweepError.colorFailed(color.label)
            }
            var rows: [GlassLabTintSweepRow] = []
            for pair in pairs {
                guard let matrices = accepted[pair.mainOnCell] else {
                    throw GlassLabTintSweepError.colorFailed(color.label)
                }
                let mainOffCell = Self.mainOffCell(for: pair.mainOnCell)
                rows.append(try makeRow(
                    color: color,
                    cell: pair.mainOnCell,
                    tint: matrices.mainOn
                ))
                rows.append(try makeRow(
                    color: color,
                    cell: mainOffCell,
                    tint: matrices.mainOff
                ))
            }
            try await onColor(color, rows.sorted(by: Self.rowSort))
        }
    }

    private func makeRow(
        color: GlassLabTintSweepColor,
        cell: GlassMaterialStyleAtlas.Cell,
        tint: GlassMaterialStyleAtlas.TintMatrix
    ) throws -> GlassLabTintSweepRow {
        let result = try GlassLabTintMatrixGate.validate(
            tint,
            expectedColor: color,
            cell: cell
        )
        return GlassLabTintSweepRow(
            colorID: color.id,
            sourceColor: tint.sourceColor,
            cell: GlassLabTintSweepCell(cell),
            matrix: tint.matrix,
            structure: result.structure,
            maximumStructureResidual: result.maximumResidual,
            lumaEndpointResidual: result.lumaEndpointResidual,
            neutralSuppressionResidual: result.neutralSuppressionResidual,
            achromaticChannelAffineResidual:
                result.achromaticChannelAffineResidual
        )
    }

    private var hostParticipates: Bool {
        guard let hostWindow else { return false }
        return NSApp.isActive
            && (hostWindow.isMainWindow || hostWindow.isKeyWindow)
    }

    private var witnessIsMainOff: Bool {
        guard let witnessWindow else { return false }
        return witnessWindow.isVisible
            && !witnessWindow.isMainWindow
            && !witnessWindow.isKeyWindow
            && NSApp.mainWindow !== witnessWindow
            && NSApp.keyWindow !== witnessWindow
    }

    private func prepareWitnessWindow() -> Bool {
        let screenFrame = hostWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        let window = GlassLabTintSweepWitnessWindow(
            contentRect: NSRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: 1,
                height: 1
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        let container = makeClippedContainer()
        content.addSubview(container)
        window.contentView = content
        witnessWindow = window
        witnessContainer = container
        window.orderFrontRegardless()
        return container.superview != nil
    }

    private func makeProbePairs(
        mainContainer: NSView,
        witnessContainer: NSView
    ) -> [ProbePair] {
        var pairs: [ProbePair] = []
        for isLight in [true, false] {
            for isClear in [false, true] {
                let mainOnCell = GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: true
                )
                pairs.append(ProbePair(
                    mainOnCell: mainOnCell,
                    mainOn: makeProbe(
                        cell: mainOnCell,
                        in: mainContainer
                    ),
                    mainOff: makeProbe(
                        cell: Self.mainOffCell(for: mainOnCell),
                        in: witnessContainer
                    )
                ))
            }
        }
        return pairs
    }

    private func makeProbe(
        cell: GlassMaterialStyleAtlas.Cell,
        in container: NSView
    ) -> NSGlassEffectView {
        let probe = NSGlassEffectView(frame: NSRect(
            x: 0,
            y: 0,
            width: plan.referenceWidth,
            height: plan.referenceShortSide
        ))
        probe.appearance = NSAppearance(
            named: cell.isLightAppearance ? .aqua : .darkAqua
        )
        GlassMaterialAccess.setVariant(cell.isClear ? 2 : 1, on: probe)
        container.addSubview(probe)
        return probe
    }

    private func makeClippedContainer() -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        return container
    }

    private func tearDown() {
        mainContainer?.removeFromSuperview()
        mainContainer = nil
        witnessWindow?.orderOut(nil)
        witnessWindow = nil
        witnessContainer = nil
    }

    private static func mainOffCell(
        for mainOn: GlassMaterialStyleAtlas.Cell
    ) -> GlassMaterialStyleAtlas.Cell {
        GlassMaterialStyleAtlas.Cell(
            isLightAppearance: mainOn.isLightAppearance,
            isClear: mainOn.isClear,
            hasMainParticipation: false
        )
    }

    private static func rowSort(
        _ lhs: GlassLabTintSweepRow,
        _ rhs: GlassLabTintSweepRow
    ) -> Bool {
        let left = (
            lhs.cell.isLightAppearance ? 0 : 1,
            lhs.cell.isClear ? 1 : 0,
            lhs.cell.hasMainParticipation ? 0 : 1
        )
        let right = (
            rhs.cell.isLightAppearance ? 0 : 1,
            rhs.cell.isClear ? 1 : 0,
            rhs.cell.hasMainParticipation ? 0 : 1
        )
        return left < right
    }
}

extension GlassLabView {
    @ViewBuilder
    func tintParameterizationSweepSection() -> some View {
        Section("Parameterization Sweep") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Capture / Resume Full Grid…") {
                        startTintParameterizationSweep(
                            plan: .fullGridV1
                        )
                    }
                    .disabled(
                        isCapturingTintParameterization
                            || isCapturingTintStudy
                            || isCapturingTintRenderedAB
                            || isRunningAtlasReadback
                    )
                    Button("Capture / Resume Focused Phase 2b…") {
                        startTintParameterizationSweep(
                            plan: .focusedPhase2b
                        )
                    }
                    .disabled(
                        isCapturingTintParameterization
                            || isCapturingTintStudy
                            || isCapturingTintRenderedAB
                            || isRunningAtlasReadback
                    )
                }
                HStack(spacing: 8) {
                    Button("Capture / Resume Hue Phase 2c…") {
                        startTintParameterizationSweep(
                            plan: .hueFractionPhase2c
                        )
                    }
                    .disabled(
                        isCapturingTintParameterization
                            || isCapturingTintStudy
                            || isCapturingTintRenderedAB
                            || isRunningAtlasReadback
                    )
                    if isCapturingTintParameterization {
                        Button("Cancel") {
                            tintParameterizationTask?.cancel()
                        }
                    }
                }
                Text(
                    "\(GlassLabTintSweepPlan.fullGridV1.colors.count)-color "
                        + "baseline, "
                        + "\(GlassLabTintSweepPlan.focusedPhase2b.colors.count)"
                        + "-color brightness follow-up, or "
                        + "\(GlassLabTintSweepPlan.hueFractionPhase2c.colors.count)"
                        + "-color hue/near-gray addendum. Each uses 8 paired "
                        + "cells, writes no runtime Tint cache, and checkpoints "
                        + "every completed color."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if let tintParameterizationStatus {
                Text(tintParameterizationStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let document = tintParameterizationDocument {
                LabeledContent("Latest Dataset") {
                    Text(
                        "\(document.completedColorCount)/"
                            + "\(document.plan.colors.count) colors · "
                            + "\(document.rows.count) rows · "
                            + "\(document.unclassifiedRowCount) unclassified"
                    )
                    .monospacedDigit()
                }
            }
        }
    }

    func startTintParameterizationSweep(plan: GlassLabTintSweepPlan) {
        guard !isCapturingTintParameterization,
              !isCapturingTintStudy,
              !isCapturingTintRenderedAB,
              !isRunningAtlasReadback else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let majorVersion =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if plan == .fullGridV1 {
            panel.nameFieldStringValue =
                "tint-parameterization-sweep-macos-\(majorVersion).json"
        } else if plan == .focusedPhase2b {
            panel.nameFieldStringValue =
                "tint-parameterization-focused-phase-2b-macos-"
                + "\(majorVersion).json"
        } else {
            panel.nameFieldStringValue =
                "tint-parameterization-hue-phase-2c-macos-"
                + "\(majorVersion).json"
        }
        panel.message = "Choose an existing checkpoint to resume or a new file."
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        isCapturingTintParameterization = true
        tintParameterizationStatus = "Preparing paired Tint probes…"
        tintParameterizationTask = Task { @MainActor in
            defer {
                isCapturingTintParameterization = false
                tintParameterizationTask = nil
            }
            do {
                let document = try await captureTintParameterizationSweep(
                    into: destination,
                    plan: plan
                )
                tintParameterizationDocument = document
                tintParameterizationStatus =
                    "Captured \(document.completedColorCount)/"
                    + "\(document.plan.colors.count) colors · "
                    + "\(document.rows.count) rows · "
                    + "\(document.unclassifiedRowCount) unclassified · "
                    + destination.path
            } catch is CancellationError {
                tintParameterizationStatus =
                    "Tint sweep cancelled; completed colors remain checkpointed."
            } catch {
                tintParameterizationStatus = "Tint sweep failed: "
                    + ((error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription)
            }
        }
    }

    @MainActor
    func captureTintParameterizationSweep(
        into destination: URL,
        plan: GlassLabTintSweepPlan
    ) async throws -> GlassLabTintParameterizationSweepDocument {
        guard let hostWindow = state.testWindow.liveControlWindow else {
            throw GlassLabTintSweepError.noHostWindow
        }
        guard let mainProbeHost = state.testWindow.liveControlProbeHost,
              mainProbeHost.window === hostWindow else {
            throw GlassLabTintSweepError.probeHostUnavailable
        }
        let currentEnvironment = GlassMaterialStyleAtlas.Environment.current(
            for: hostWindow.screen
        )
        let environment = GlassLabTintParameterizationSweepDocument.Environment(
            osMajorVersion:
                currentEnvironment.resolvedOSMajorVersion
                    ?? ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            displaySignature: currentEnvironment.displaySignature,
            atlasSchemaVersion: GlassMaterialStyleAtlas.currentSchemaVersion
        )
        var document = try Self.loadTintSweepCheckpoint(
            at: destination,
            plan: plan,
            operatingSystem:
                ProcessInfo.processInfo.operatingSystemVersionString,
            environment: environment
        ) ?? GlassLabTintParameterizationSweepDocument(
            formatVersion: 1,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            operatingSystem:
                ProcessInfo.processInfo.operatingSystemVersionString,
            environment: environment,
            plan: plan,
            complete: false,
            completedColorCount: 0,
            rows: [],
            failure: nil
        )
        try Self.writeTintSweepCheckpoint(document, to: destination)

        let completed = Set(document.rows.map(\.colorID))
        let remaining = plan.colors.filter { !completed.contains($0.id) }
        if remaining.isEmpty {
            try Self.validateTintSweepCompleteness(document)
            document.complete = true
            document.failure = nil
            try Self.writeTintSweepCheckpoint(document, to: destination)
            return document
        }

        let session = GlassLabTintSweepCaptureSession(
            hostWindow: hostWindow,
            mainProbeHost: mainProbeHost,
            plan: plan
        )
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .idleSystemSleepDisabled,
                .idleDisplaySleepDisabled,
            ],
            reason: "Capturing Tint parameterization plan \(plan.id)"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        do {
            try await session.capture(colors: remaining) { color, rows in
                document.rows.removeAll { $0.colorID == color.id }
                document.rows.append(contentsOf: rows)
                document.rows.sort(by: Self.tintSweepRowSort)
                document.completedColorCount = Set(
                    document.rows.map(\.colorID)
                ).count
                document.complete = false
                document.failure = nil
                tintParameterizationDocument = document
                tintParameterizationStatus =
                    "Captured \(document.completedColorCount)/"
                    + "\(plan.colors.count) · \(color.label)"
                try Self.writeTintSweepCheckpoint(document, to: destination)
            }
            try Self.validateTintSweepCompleteness(document)
            document.complete = true
            document.failure = nil
            try Self.writeTintSweepCheckpoint(document, to: destination)
            return document
        } catch {
            document.complete = false
            document.failure = error is CancellationError
                ? "cancelled"
                : ((error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription)
            try? Self.writeTintSweepCheckpoint(document, to: destination)
            throw error
        }
    }

    private static func loadTintSweepCheckpoint(
        at url: URL,
        plan: GlassLabTintSweepPlan,
        operatingSystem: String,
        environment:
            GlassLabTintParameterizationSweepDocument.Environment
    ) throws -> GlassLabTintParameterizationSweepDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        let document = try JSONDecoder().decode(
            GlassLabTintParameterizationSweepDocument.self,
            from: data
        )
        guard document.formatVersion == 1 else {
            throw GlassLabTintSweepError.invalidExistingDocument(
                "unsupported formatVersion \(document.formatVersion)"
            )
        }
        guard document.plan == plan else {
            throw GlassLabTintSweepError.invalidExistingDocument(
                "capture plan differs from \(plan.id)"
            )
        }
        guard document.operatingSystem == operatingSystem,
              document.environment == environment else {
            throw GlassLabTintSweepError.invalidExistingDocument(
                "OS build or display signature changed"
            )
        }
        let colorsByID = Dictionary(
            uniqueKeysWithValues: plan.colors.map { ($0.id, $0) }
        )
        for row in document.rows {
            guard let expectedColor = colorsByID[row.colorID] else {
                throw GlassLabTintSweepError.invalidExistingDocument(
                    "unknown color id \(row.colorID)"
                )
            }
            let result = try GlassLabTintMatrixGate.validate(
                GlassMaterialStyleAtlas.TintMatrix(
                    sourceColor: row.sourceColor,
                    matrix: row.matrix
                ),
                expectedColor: expectedColor,
                cell: row.cell.atlasCell
            )
            guard tintSweepStructuresMatch(
                stored: row.structure,
                measured: result.structure
            ) else {
                throw GlassLabTintSweepError.invalidExistingDocument(
                    "\(row.colorID) · \(row.cell.label) structure changed"
                )
            }
        }
        let grouped = Dictionary(grouping: document.rows, by: \.colorID)
        guard grouped.values.allSatisfy({
            $0.count == 8
                && Set($0.map(\.cell)) == tintSweepExpectedCells
        }) else {
            throw GlassLabTintSweepError.invalidExistingDocument(
                "one or more colors do not contain exactly 8 unique cells"
            )
        }
        guard document.completedColorCount == grouped.count else {
            throw GlassLabTintSweepError.invalidExistingDocument(
                "completedColorCount does not match the checkpoint rows"
            )
        }
        return document
    }

    private static func validateTintSweepCompleteness(
        _ document: GlassLabTintParameterizationSweepDocument
    ) throws {
        let expected = document.plan.colors.count * 8
        guard document.rows.count == expected else {
            throw GlassLabTintSweepError.incomplete(
                expected: expected,
                actual: document.rows.count
            )
        }
        let grouped = Dictionary(grouping: document.rows, by: \.colorID)
        for color in document.plan.colors {
            let rows = grouped[color.id] ?? []
            guard rows.count == 8,
                  Set(rows.map(\.cell)) == tintSweepExpectedCells else {
                throw GlassLabTintSweepError.incomplete(
                    expected: 8,
                    actual: rows.count
                )
            }
            for row in rows {
                let result = try GlassLabTintMatrixGate.validate(
                    GlassMaterialStyleAtlas.TintMatrix(
                        sourceColor: row.sourceColor,
                        matrix: row.matrix
                    ),
                    expectedColor: color,
                    cell: row.cell.atlasCell
                )
                guard tintSweepStructuresMatch(
                    stored: row.structure,
                    measured: result.structure
                ) else {
                    throw GlassLabTintSweepError.invalidExistingDocument(
                        "\(row.colorID) · \(row.cell.label) structure changed"
                    )
                }
            }
        }
    }

    private static var tintSweepExpectedCells: Set<GlassLabTintSweepCell> {
        Set(
            [true, false].flatMap { isLight in
                [false, true].flatMap { isClear in
                    [true, false].map { hasMain in
                        GlassLabTintSweepCell(GlassMaterialStyleAtlas.Cell(
                            isLightAppearance: isLight,
                            isClear: isClear,
                            hasMainParticipation: hasMain
                        ))
                    }
                }
            }
        )
    }

    private static func tintSweepStructuresMatch(
        stored: GlassLabTintMatrixStructure,
        measured: GlassLabTintMatrixStructure
    ) -> Bool {
        stored == measured
            || (
                stored == .unclassified
                    && measured == .achromaticChannelAffine
            )
    }

    private static func writeTintSweepCheckpoint(
        _ document: GlassLabTintParameterizationSweepDocument,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    private static func tintSweepRowSort(
        _ lhs: GlassLabTintSweepRow,
        _ rhs: GlassLabTintSweepRow
    ) -> Bool {
        if lhs.colorID != rhs.colorID { return lhs.colorID < rhs.colorID }
        let left = (
            lhs.cell.isLightAppearance ? 0 : 1,
            lhs.cell.isClear ? 1 : 0,
            lhs.cell.hasMainParticipation ? 0 : 1
        )
        let right = (
            rhs.cell.isLightAppearance ? 0 : 1,
            rhs.cell.isClear ? 1 : 0,
            rhs.cell.hasMainParticipation ? 0 : 1
        )
        return left < right
    }
}
#endif
