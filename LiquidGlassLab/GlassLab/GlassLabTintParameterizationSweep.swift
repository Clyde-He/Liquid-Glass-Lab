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
}

struct GlassLabTintSweepRow: Codable, Hashable, Sendable {
    var colorID: String
    var sourceColor: GlassMaterialColorValue
    var cell: GlassLabTintSweepCell
    var matrix: [Float]
    var structure: GlassLabTintMatrixStructure
    var maximumStructureResidual: Double
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
}

enum GlassLabTintSweepError: LocalizedError {
    case noHostWindow
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
            "Tint structure gate failed: \(reason)"
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
        if cell.hasMainParticipation {
            guard rankOneResidual <= tolerance else {
                throw GlassLabTintSweepError.invalidMatrix(
                    "\(expectedColor.id) · \(GlassLabTintSweepCell(cell).label) "
                        + "is not rank-1 Rec.709 luma "
                        + "(residual \(rankOneResidual))"
                )
            }
            return Result(
                structure: .lumaEndpoints,
                maximumResidual: max(rankOneResidual, alphaRowResidual)
            )
        }
        if rankOneResidual <= tolerance {
            return Result(
                structure: .lumaEndpoints,
                maximumResidual: max(rankOneResidual, alphaRowResidual)
            )
        }
        guard neutralResidual <= tolerance else {
            throw GlassLabTintSweepError.invalidMatrix(
                "\(expectedColor.id) · \(GlassLabTintSweepCell(cell).label) "
                    + "is neither luma-endpoint nor neutral suppression "
                    + "(residuals \(rankOneResidual), \(neutralResidual))"
            )
        }
        return Result(
            structure: .neutralSuppression,
            maximumResidual: max(neutralResidual, alphaRowResidual)
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
    private let plan: GlassLabTintSweepPlan
    private var mainContainer: NSView?
    private var witnessWindow: GlassLabTintSweepWitnessWindow?
    private var witnessContainer: NSView?

    init(hostWindow: NSWindow, plan: GlassLabTintSweepPlan) {
        self.hostWindow = hostWindow
        self.plan = plan
    }

    func capture(
        colors: [GlassLabTintSweepColor],
        onColor: @MainActor (
            _ color: GlassLabTintSweepColor,
            _ rows: [GlassLabTintSweepRow]
        ) async throws -> Void
    ) async throws {
        guard let hostWindow, let contentView = hostWindow.contentView else {
            throw GlassLabTintSweepError.noHostWindow
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        hostWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        guard hostParticipates else {
            throw GlassLabTintSweepError.hostNotParticipating
        }

        let mainContainer = makeClippedContainer()
        contentView.addSubview(mainContainer)
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

        contentView.layoutSubtreeIfNeeded()
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
            contentView.layoutSubtreeIfNeeded()
            witnessWindow?.contentView?.layoutSubtreeIfNeeded()
            for pair in pairs {
                pair.mainOn.tintColor = color.nsColor
                pair.mainOff.tintColor = color.nsColor
            }
            contentView.layoutSubtreeIfNeeded()
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
            maximumStructureResidual: result.maximumResidual
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
                    Button(
                        isCapturingTintParameterization
                            ? "Capturing…" : "Capture / Resume Full Grid…"
                    ) {
                        startTintParameterizationSweep()
                    }
                    .disabled(
                        isCapturingTintParameterization
                            || isCapturingTintStudy
                            || isCapturingAtlas
                            || isRunningAtlasReadback
                    )
                    if isCapturingTintParameterization {
                        Button("Cancel") {
                            tintParameterizationTask?.cancel()
                        }
                    }
                }
                Text(
                    "\(GlassLabTintSweepPlan.fullGridV1.colors.count) colors × "
                        + "8 paired cells. One hidden probe session, no runtime "
                        + "Tint cache writes. Every completed color is atomically "
                        + "checkpointed and can be resumed."
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
                            + "\(document.rows.count) rows"
                    )
                    .monospacedDigit()
                }
            }
        }
    }

    func startTintParameterizationSweep() {
        guard !isCapturingTintParameterization,
              !isCapturingTintStudy,
              !isCapturingAtlas,
              !isRunningAtlasReadback else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let majorVersion =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        panel.nameFieldStringValue =
            "tint-parameterization-sweep-macos-\(majorVersion).json"
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
                    into: destination
                )
                tintParameterizationDocument = document
                tintParameterizationStatus =
                    "Captured \(document.completedColorCount)/"
                    + "\(document.plan.colors.count) colors · "
                    + "\(document.rows.count) rows · \(destination.path)"
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
        into destination: URL
    ) async throws -> GlassLabTintParameterizationSweepDocument {
        guard let hostWindow = state.testWindow.liveControlWindow
                ?? NSApp.mainWindow else {
            throw GlassLabTintSweepError.noHostWindow
        }
        let plan = GlassLabTintSweepPlan.fullGridV1
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
            plan: plan
        )
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .idleSystemSleepDisabled,
                .idleDisplaySleepDisabled,
            ],
            reason: "Capturing the Tint parameterization full-grid sweep"
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
            guard result.structure == row.structure else {
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
                guard result.structure == row.structure else {
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
