//
//  GlassLabTintRenderedAB.swift
//  LiquidGlassLab
//
//  Rendered acceptance for the macOS 27 Tint closed form. Each row captures
//  the system-resolved matrix and two unchanged WindowServer frames, then
//  replaces only that matrix with the synthesized value and captures a third
//  frame. The A/A pair establishes the row's screenshot noise floor.
//

#if os(macOS)
import AppKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

struct GlassLabTintRenderedABColor: Codable, Hashable, Sendable {
    var id: String
    var label: String
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var colorValue: GlassMaterialColorValue {
        GlassMaterialColorValue(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}

struct GlassLabTintRenderedABPixelMetrics: Codable, Hashable, Sendable {
    var width: Int
    var height: Int
    var maximumRGBCodeDelta: Int
    var p99RGBCodeDelta: Int
    var rootMeanSquareRGBCodeDelta: Double
    var meanAbsoluteRGBCodeDelta: Double
    var changedPixelFraction: Double
}

struct GlassLabTintRenderedABRow: Codable, Hashable, Sendable {
    var colorID: String
    var colorLabel: String
    var sourceColor: GlassMaterialColorValue
    var resolvedSourceColor: GlassMaterialColorValue?
    var cell: GlassLabTintSweepCell
    var family: String?
    var capturedMatrix: [Float]?
    var synthesizedMatrix: [Float]?
    var maximumMatrixResidual: Double?
    var synthesizedReadbackResidual: Double?
    var repeatPixels: GlassLabTintRenderedABPixelMetrics?
    var synthesizedPixels: GlassLabTintRenderedABPixelMetrics?
    var pixelAttemptCount: Int
    var repeatNoiseAccepted: Bool
    var renderedDifferenceAccepted: Bool
    var passed: Bool
    var failure: String?
}

struct GlassLabTintRenderedABDocument: Codable, Sendable {
    struct Environment: Codable, Hashable, Sendable {
        var osMajorVersion: Int
        var displaySignature: String
        var atlasSchemaVersion: Int
        var captureAPI: String
        var pixelFormat: String
    }

    var formatVersion: Int
    var capturedAt: String
    var operatingSystem: String
    var environment: Environment
    var colors: [GlassLabTintRenderedABColor]
    var expectedRowCount: Int
    var rows: [GlassLabTintRenderedABRow]
    var complete: Bool
    var passed: Bool

    var report: String {
        let failures = rows.filter { !$0.passed }
        let maximumMatrixResidual = rows.compactMap(\.maximumMatrixResidual).max()
            ?? 0
        let maximumRepeatDelta = rows.compactMap {
            $0.repeatPixels?.maximumRGBCodeDelta
        }.max() ?? 0
        let maximumSynthesizedDelta = rows.compactMap {
            $0.synthesizedPixels?.maximumRGBCodeDelta
        }.max() ?? 0
        return [
            "== Tint Rendered A/B Acceptance ==",
            "OS major: \(environment.osMajorVersion)",
            "Rows: \(rows.count)/\(expectedRowCount)",
            "Maximum matrix residual: "
                + String(format: "%.6e", maximumMatrixResidual),
            "Maximum repeat RGB code delta: \(maximumRepeatDelta)",
            "Maximum synthesized RGB code delta: \(maximumSynthesizedDelta)",
            "Failures: \(failures.count)",
            "Result: \(passed ? "PASSED" : "FAILED")",
        ].joined(separator: "\n")
    }

    var failureReport: String {
        let failures = rows.filter { !$0.passed }
        guard !failures.isEmpty else { return "Failure rows: none" }
        return failures.map { row in
            let matrix = row.maximumMatrixResidual.map {
                String(format: "%.6e", $0)
            } ?? "n/a"
            let repeatPixels = row.repeatPixels.map {
                "max=\($0.maximumRGBCodeDelta) "
                    + "p99=\($0.p99RGBCodeDelta) "
                    + "rms=\(String(format: "%.4f", $0.rootMeanSquareRGBCodeDelta))"
            } ?? "n/a"
            let synthesizedPixels = row.synthesizedPixels.map {
                "max=\($0.maximumRGBCodeDelta) "
                    + "p99=\($0.p99RGBCodeDelta) "
                    + "rms=\(String(format: "%.4f", $0.rootMeanSquareRGBCodeDelta))"
            } ?? "n/a"
            return [
                row.cell.label + " · " + row.colorID,
                "matrix=" + matrix,
                "A/A " + repeatPixels,
                "A/B " + synthesizedPixels,
                row.failure ?? "unknown failure",
            ].joined(separator: " · ")
        }.joined(separator: "\n")
    }
}

enum GlassLabTintRenderedABError: LocalizedError {
    case unsupportedOSMajor(Int)
    case activeOverrides
    case missingWindow
    case missingGlass
    case windowNotShareable
    case missingTintMatrix
    case imageConversion
    case imageSizeChanged
    case contextRejected(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedOSMajor(major):
            "Tint rendered A/B is certified only for macOS 27; found \(major)."
        case .activeOverrides:
            "Disable Filter, Rim, and Color Matrix overrides before A/B."
        case .missingWindow:
            "Tint rendered A/B could not create the controlled test window."
        case .missingGlass:
            "Tint rendered A/B could not resolve the live NSGlassEffectView."
        case .windowNotShareable:
            "ScreenCaptureKit did not expose the app's controlled test window."
        case .missingTintMatrix:
            "The live Tint branch did not resolve a complete color matrix."
        case .imageConversion:
            "The ScreenCaptureKit image could not be normalized to RGBA8."
        case .imageSizeChanged:
            "The controlled window changed pixel dimensions during one A/B row."
        case let .contextRejected(context):
            "Tint rendered A/B could not establish \(context)."
        }
    }
}

enum GlassLabTintRenderedABPlan {
    static let colors: [GlassLabTintRenderedABColor] = [
        .init(
            id: "gray-000",
            label: "Exact Black",
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0.8
        ),
        .init(
            id: "gray-500",
            label: "Mid Gray",
            red: 0.5,
            green: 0.5,
            blue: 0.5,
            alpha: 0.8
        ),
        .init(
            id: "known-salmon",
            label: "Known Salmon",
            red: 1,
            green: 0.45,
            blue: 0.35,
            alpha: 0.8
        ),
        .init(
            id: "rgb-holdout-teal",
            label: "RGB Holdout Teal",
            red: 0.08,
            green: 0.78,
            blue: 0.71,
            alpha: 0.8
        ),
        .init(
            id: "gamut-red",
            label: "Gamut Edge Red",
            red: 1,
            green: 0,
            blue: 0,
            alpha: 0.8
        ),
        .init(
            id: "boundary-c0300-v1000",
            label: "Boundary C0.0003",
            red: 1,
            green: 0.999785,
            blue: 0.9997,
            alpha: 0.8
        ),
        .init(
            id: "boundary-c0400-v1000",
            label: "Boundary C0.0004",
            red: 1,
            green: 0.9997133333333333,
            blue: 0.9996,
            alpha: 0.8
        ),
        .init(
            id: "boundary-c0600-v1000",
            label: "Boundary C0.0006",
            red: 1,
            green: 0.99957,
            blue: 0.9994,
            alpha: 0.8
        ),
    ]

    static let cells: [GlassMaterialStyleAtlas.Cell] = {
        var result: [GlassMaterialStyleAtlas.Cell] = []
        for isLightAppearance in [true, false] {
            for isClear in [false, true] {
                for hasMainParticipation in [false, true] {
                    result.append(GlassMaterialStyleAtlas.Cell(
                        isLightAppearance: isLightAppearance,
                        isClear: isClear,
                        hasMainParticipation: hasMainParticipation
                    ))
                }
            }
        }
        return result
    }()
}

private struct GlassLabTintRenderedABPixelBuffer {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    init(image: CGImage) throws {
        width = image.width
        height = image.height
        let byteCount = width * height * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard width > 0,
              height > 0,
              let colorSpace,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo
              ),
              let data = context.data else {
            throw GlassLabTintRenderedABError.imageConversion
        }
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        bytes = Array(
            UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: byteCount
            )
        )
    }

    func difference(
        from other: GlassLabTintRenderedABPixelBuffer
    ) throws -> GlassLabTintRenderedABPixelMetrics {
        guard width == other.width,
              height == other.height,
              bytes.count == other.bytes.count else {
            throw GlassLabTintRenderedABError.imageSizeChanged
        }
        var histogram = [Int](repeating: 0, count: 256)
        var absoluteSum = 0.0
        var squaredSum = 0.0
        var changedPixels = 0
        let pixelCount = width * height

        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            var pixelChanged = false
            for channel in 0..<3 {
                let delta = abs(
                    Int(bytes[offset + channel])
                        - Int(other.bytes[offset + channel])
                )
                histogram[delta] += 1
                absoluteSum += Double(delta)
                squaredSum += Double(delta * delta)
                pixelChanged = pixelChanged || delta != 0
            }
            if pixelChanged { changedPixels += 1 }
        }

        let channelCount = pixelCount * 3
        let p99Target = Int(ceil(Double(channelCount) * 0.99))
        var cumulative = 0
        var p99 = 0
        for delta in histogram.indices {
            cumulative += histogram[delta]
            if cumulative >= p99Target {
                p99 = delta
                break
            }
        }
        let maximum = histogram.lastIndex(where: { $0 != 0 }) ?? 0
        return GlassLabTintRenderedABPixelMetrics(
            width: width,
            height: height,
            maximumRGBCodeDelta: maximum,
            p99RGBCodeDelta: p99,
            rootMeanSquareRGBCodeDelta:
                sqrt(squaredSum / Double(channelCount)),
            meanAbsoluteRGBCodeDelta:
                absoluteSum / Double(channelCount),
            changedPixelFraction:
                Double(changedPixels) / Double(pixelCount)
        )
    }
}

@MainActor
private final class GlassLabOwnWindowScreenshotter {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration

    private init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) {
        self.filter = filter
        self.configuration = configuration
    }

    static func make(
        for window: NSWindow
    ) async throws -> GlassLabOwnWindowScreenshotter {
        let content = try await SCShareableContent.currentProcess
        let windowID = CGWindowID(window.windowNumber)
        guard let shareableWindow = content.windows.first(where: {
            $0.windowID == windowID
        }) else {
            throw GlassLabTintRenderedABError.windowNotShareable
        }
        let filter = SCContentFilter(
            desktopIndependentWindow: shareableWindow
        )
        let configuration = SCStreamConfiguration()
        configuration.width = Int(
            ceil(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        )
        configuration.height = Int(
            ceil(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        )
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return GlassLabOwnWindowScreenshotter(
            filter: filter,
            configuration: configuration
        )
    }

    func capture() async throws -> GlassLabTintRenderedABPixelBuffer {
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return try GlassLabTintRenderedABPixelBuffer(image: image)
    }
}

extension GlassLabView {
    @ViewBuilder
    func tintRenderedABSection() -> some View {
        Section("Rendered A/B Acceptance") {
            Text(
                "Compares the live system-resolved Tint matrix with the "
                    + "macOS 27 closed form through the real WindowServer "
                    + "render path. Eight risk colors cover all eight "
                    + "appearance/material/participation cells. Every row "
                    + "includes an unchanged A/A pair as its noise floor."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Run Rendered A/B…") {
                    startTintRenderedABAcceptance()
                }
                .disabled(
                    isCapturingTintRenderedAB
                        || isCapturingTintParameterization
                        || isCapturingTintStudy
                        || isCapturingAtlas
                        || isRunningAtlasReadback
                )
                if isCapturingTintRenderedAB {
                    Button("Cancel") {
                        tintRenderedABTask?.cancel()
                    }
                }
            }

            if let tintRenderedABStatus {
                Text(tintRenderedABStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let document = tintRenderedABDocument {
                Text(document.report)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    @MainActor
    func startTintRenderedABAcceptance() {
        guard !isCapturingTintRenderedAB,
              !isCapturingTintParameterization,
              !isCapturingTintStudy,
              !isCapturingAtlas,
              !isRunningAtlasReadback else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "tint-rendered-ab-macos-"
            + "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
            + ".json"
        panel.message =
            "Choose where to save the captured-vs-synthesized pixel report."
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        tintRenderedABDocument = nil
        tintRenderedABStatus = "Preparing controlled rendered A/B context…"
        isCapturingTintRenderedAB = true
        tintRenderedABTask = Task { @MainActor in
            defer {
                isCapturingTintRenderedAB = false
                tintRenderedABTask = nil
            }
            do {
                let document = try await performTintRenderedABAcceptance()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(document).write(
                    to: destination,
                    options: .atomic
                )
                tintRenderedABDocument = document
                state.reportOutput = document.report
                tintRenderedABStatus =
                    "\(document.passed ? "PASSED" : "FAILED") · "
                    + "\(document.rows.count)/"
                    + "\(document.expectedRowCount) rows · "
                    + destination.path
            } catch is CancellationError {
                tintRenderedABStatus =
                    "Rendered A/B cancelled; partial rows were discarded."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                tintRenderedABStatus = "Rendered A/B failed: \(message)"
                state.reportOutput = tintRenderedABStatus ?? message
            }
        }
    }

    @MainActor
    func performTintRenderedABAcceptance() async throws
        -> GlassLabTintRenderedABDocument {
        let majorVersion =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard GlassMaterialTintMatrixSynthesizer.supportedOSMajorVersions
                .contains(majorVersion)
        else {
            throw GlassLabTintRenderedABError.unsupportedOSMajor(majorVersion)
        }
        guard !state.hasActiveOverrides else {
            throw GlassLabTintRenderedABError.activeOverrides
        }

        let originalRenderer = state.rendererMode
        let originalRecipePage = selectedRecipePage
        let originalVariant = state.variant
        let originalSubvariant = state.subvariant
        let originalSubdued = state.isSubdued
        let originalScrim = state.hasScrim
        let originalReducedTintOpacity = state.hasReducedTintOpacity
        let originalAdaptiveAppearance = state.adaptiveAppearance
        let originalTint = state.tintColor
        let originalWidth = state.glassWidth
        let originalHeight = state.glassHeight
        let originalCornerRadius = state.cornerRadius
        let originalHost = state.windowHostType
        let originalAppearance = state.testAppearance
        let originalBackdrop = state.testBackdrop
        let originalMain = state.isTestWindowMain
        let originalKey = state.isTestWindowKey
        let originalPadding = state.windowPadding
        let originalVisibility = state.isTestWindowVisible
        defer {
            state.rendererMode = originalRenderer
            selectedRecipePage = originalRecipePage
            state.variant = originalVariant
            state.subvariant = originalSubvariant
            state.isSubdued = originalSubdued
            state.hasScrim = originalScrim
            state.hasReducedTintOpacity = originalReducedTintOpacity
            state.adaptiveAppearance = originalAdaptiveAppearance
            state.tintColor = originalTint
            state.glassWidth = originalWidth
            state.glassHeight = originalHeight
            state.cornerRadius = originalCornerRadius
            state.windowHostType = originalHost
            state.testAppearance = originalAppearance
            state.testBackdrop = originalBackdrop
            state.isTestWindowMain = originalMain
            state.isTestWindowKey = originalKey
            state.windowPadding = originalPadding
            state.isTestWindowVisible = originalVisibility
            state.testWindow.sync(with: state)
            scheduleLiveReadoutRefresh(refreshSchema: true)
        }

        configureTintRenderedABContext()
        try await waitUntilApplicationIsActive(
            progress: "Tint rendered A/B paused while app is inactive."
        )
        try await Task.sleep(for: .milliseconds(600))
        guard let window = state.testWindow.liveWindow else {
            throw GlassLabTintRenderedABError.missingWindow
        }
        let screenshotter = try await GlassLabOwnWindowScreenshotter.make(
            for: window
        )
        reportTintRenderedABProgress("ScreenCaptureKit window ready.")
        let currentEnvironment = GlassMaterialStyleAtlas.Environment.current(
            for: window.screen
        )
        var rows: [GlassLabTintRenderedABRow] = []
        let expectedRowCount = GlassLabTintRenderedABPlan.colors.count
            * GlassLabTintRenderedABPlan.cells.count

        for cell in GlassLabTintRenderedABPlan.cells {
            for color in GlassLabTintRenderedABPlan.colors {
                try Task.checkCancellation()
                reportTintRenderedABProgress(
                    "Rendered A/B \(rows.count + 1)/\(expectedRowCount) · "
                    + "\(GlassLabTintSweepCell(cell).label) · \(color.label)"
                )
                do {
                    let row = try await captureTintRenderedABRow(
                        color: color,
                        cell: cell,
                        screenshotter: screenshotter
                    )
                    rows.append(row)
                    reportTintRenderedABProgress(
                        "Completed \(rows.count)/\(expectedRowCount) · "
                            + (row.passed ? "PASS" : "FAIL")
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    rows.append(GlassLabTintRenderedABRow(
                        colorID: color.id,
                        colorLabel: color.label,
                        sourceColor: color.colorValue,
                        resolvedSourceColor: nil,
                        cell: GlassLabTintSweepCell(cell),
                        family: nil,
                        capturedMatrix: nil,
                        synthesizedMatrix: nil,
                        maximumMatrixResidual: nil,
                        synthesizedReadbackResidual: nil,
                        repeatPixels: nil,
                        synthesizedPixels: nil,
                        pixelAttemptCount: 0,
                        repeatNoiseAccepted: false,
                        renderedDifferenceAccepted: false,
                        passed: false,
                        failure:
                            (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
                    ))
                    reportTintRenderedABProgress(
                        "Completed \(rows.count)/\(expectedRowCount) · ERROR · "
                            + (
                                (error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription
                            )
                    )
                }
            }
        }

        let complete = rows.count == expectedRowCount
        let passed = complete && rows.allSatisfy(\.passed)
        return GlassLabTintRenderedABDocument(
            formatVersion: 1,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            operatingSystem:
                ProcessInfo.processInfo.operatingSystemVersionString,
            environment: .init(
                osMajorVersion:
                    currentEnvironment.resolvedOSMajorVersion ?? majorVersion,
                displaySignature: currentEnvironment.displaySignature,
                atlasSchemaVersion:
                    GlassMaterialStyleAtlas.currentSchemaVersion,
                captureAPI: "ScreenCaptureKit.currentProcess",
                pixelFormat: "sRGB RGBA8"
            ),
            colors: GlassLabTintRenderedABPlan.colors,
            expectedRowCount: expectedRowCount,
            rows: rows,
            complete: complete,
            passed: passed
        )
    }

    @MainActor
    private func configureTintRenderedABContext() {
        state.rendererMode = .recipe
        selectedRecipePage = .tint
        state.variant = 1
        state.subvariant = ""
        state.isSubdued = false
        state.hasScrim = false
        state.hasReducedTintOpacity = false
        state.adaptiveAppearance = 2
        state.tintColor = nil
        state.glassWidth = 480
        state.glassHeight = 200
        state.cornerRadius = 16
        state.windowHostType = .window
        state.testAppearance = .light
        state.testBackdrop = .ambient
        state.isTestWindowMain = false
        state.isTestWindowKey = false
        state.windowPadding = 40
        state.isTestWindowVisible = true
        state.testWindow.sync(with: state)
    }

    @MainActor
    private func reportTintRenderedABProgress(_ message: String) {
        tintRenderedABStatus = message
        guard ProcessInfo.processInfo.arguments.contains(
            "--verify-tint-rendered-ab"
        ) else {
            return
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    @MainActor
    private func captureTintRenderedABRow(
        color: GlassLabTintRenderedABColor,
        cell: GlassMaterialStyleAtlas.Cell,
        screenshotter: GlassLabOwnWindowScreenshotter
    ) async throws -> GlassLabTintRenderedABRow {
        state.testAppearance = cell.isLightAppearance ? .light : .dark
        state.variant = cell.isClear ? 2 : 1
        state.isTestWindowMain = cell.hasMainParticipation
        state.isTestWindowKey = false
        state.tintColor = color.colorValue.nsColor
        state.testWindow.sync(with: state)

        let (glass, tintLayer, capturedMatrix, resolvedColor) =
            try await settledTintRenderedABTarget(
                color: color,
                cell: cell
            )
        guard let synthesizedMatrix =
            GlassMaterialTintMatrixSynthesizer.matrix(
                for: resolvedColor,
                cell: cell,
                osMajorVersion: ProcessInfo.processInfo
                    .operatingSystemVersion.majorVersion
            ) else {
            throw GlassLabTintRenderedABError.missingTintMatrix
        }
        let family = GlassMaterialTintMatrixSynthesizer.family(
            for: [
                resolvedColor.red,
                resolvedColor.green,
                resolvedColor.blue,
            ],
            cell: cell,
            osMajorVersion: ProcessInfo.processInfo
                .operatingSystemVersion.majorVersion
        )
        let matrixResidual = Self.maximumDifference(
            capturedMatrix,
            synthesizedMatrix
        )

        defer {
            GlassMaterialAccess.setColorMatrix(
                capturedMatrix,
                on: tintLayer
            )
        }
        var pixelAttemptCount = 0
        var repeatMetrics: GlassLabTintRenderedABPixelMetrics?
        var synthesizedMetrics: GlassLabTintRenderedABPixelMetrics?
        var readbackResidual = Double.infinity
        var repeatAccepted = false
        var renderedAccepted = false

        repeat {
            pixelAttemptCount += 1
            GlassMaterialAccess.setColorMatrix(
                capturedMatrix,
                on: tintLayer
            )
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(100))
            let capturedPixels = try await screenshotter.capture()
            try await Task.sleep(for: .milliseconds(100))
            let repeatPixels = try await screenshotter.capture()
            let currentRepeatMetrics = try repeatPixels.difference(
                from: capturedPixels
            )

            GlassMaterialAccess.setColorMatrix(
                synthesizedMatrix,
                on: tintLayer
            )
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(100))
            guard glass === state.testWindow.liveGlass,
                  GlassMaterialAccess.tintMatrixLayer(under: glass)
                    === tintLayer,
                  let readback = GlassMaterialAccess.colorMatrix(
                      on: tintLayer
                  ) else {
                throw GlassLabTintRenderedABError.missingTintMatrix
            }
            readbackResidual = Self.maximumDifference(
                readback,
                synthesizedMatrix
            )
            let synthesizedPixels = try await screenshotter.capture()
            let currentSynthesizedMetrics =
                try synthesizedPixels.difference(from: repeatPixels)

            repeatMetrics = currentRepeatMetrics
            synthesizedMetrics = currentSynthesizedMetrics
            repeatAccepted =
                currentRepeatMetrics.maximumRGBCodeDelta <= 4
                    && currentRepeatMetrics.p99RGBCodeDelta <= 1
                    && currentRepeatMetrics
                        .rootMeanSquareRGBCodeDelta <= 0.5
            renderedAccepted =
                currentSynthesizedMetrics.maximumRGBCodeDelta
                    <= max(
                        4,
                        currentRepeatMetrics.maximumRGBCodeDelta + 1
                    )
                    && currentSynthesizedMetrics.p99RGBCodeDelta
                        <= max(
                            1,
                            currentRepeatMetrics.p99RGBCodeDelta + 1
                        )
                    && currentSynthesizedMetrics
                        .rootMeanSquareRGBCodeDelta
                        <= max(
                            0.25,
                            currentRepeatMetrics
                                .rootMeanSquareRGBCodeDelta + 0.15
                        )
        } while (!repeatAccepted || !renderedAccepted)
            && pixelAttemptCount < 3

        guard let repeatMetrics, let synthesizedMetrics else {
            throw GlassLabTintRenderedABError.imageConversion
        }
        let matrixAccepted = matrixResidual <= 0.0002
            && readbackResidual <= 0.000001
        let passed = matrixAccepted && repeatAccepted && renderedAccepted
        var failures: [String] = []
        if matrixResidual > 0.0002 {
            failures.append(String(
                format: "matrix residual %.6e exceeds 2e-4",
                matrixResidual
            ))
        }
        if readbackResidual > 0.000001 {
            failures.append(String(
                format: "matrix readback residual %.6e exceeds 1e-6",
                readbackResidual
            ))
        }
        if !repeatAccepted {
            failures.append("A/A screenshot noise exceeds the admission gate")
        }
        if !renderedAccepted {
            failures.append("captured/synthesized pixels exceed the noise floor")
        }

        return GlassLabTintRenderedABRow(
            colorID: color.id,
            colorLabel: color.label,
            sourceColor: color.colorValue,
            resolvedSourceColor: resolvedColor,
            cell: GlassLabTintSweepCell(cell),
            family: family.rawValue,
            capturedMatrix: capturedMatrix,
            synthesizedMatrix: synthesizedMatrix,
            maximumMatrixResidual: matrixResidual,
            synthesizedReadbackResidual: readbackResidual,
            repeatPixels: repeatMetrics,
            synthesizedPixels: synthesizedMetrics,
            pixelAttemptCount: pixelAttemptCount,
            repeatNoiseAccepted: repeatAccepted,
            renderedDifferenceAccepted: renderedAccepted,
            passed: passed,
            failure: failures.isEmpty
                ? nil : failures.joined(separator: "; ")
        )
    }

    @MainActor
    private func settledTintRenderedABTarget(
        color: GlassLabTintRenderedABColor,
        cell: GlassMaterialStyleAtlas.Cell
    ) async throws -> (
        NSGlassEffectView,
        CALayer,
        [Float],
        GlassMaterialColorValue
    ) {
        var previousMatrix: [Float]?
        var stableReadCount = 0
        for _ in 0..<30 {
            try Task.checkCancellation()
            try await waitUntilApplicationIsActive(
                progress: tintRenderedABStatus
                    ?? "Tint rendered A/B paused while app is inactive."
            )
            state.testWindow.sync(with: state)
            try await Task.sleep(for: .milliseconds(100))
            guard let glass = state.testWindow.liveGlass else {
                previousMatrix = nil
                stableReadCount = 0
                continue
            }
            let appearanceMatches = (
                cell.isLightAppearance
                    ? GlassLabTestAppearance.light
                    : GlassLabTestAppearance.dark
            ).matches(glass.effectiveAppearance)
            guard appearanceMatches,
                  state.testWindow.isActuallyMain
                    == cell.hasMainParticipation,
                  !state.testWindow.isActuallyKey,
                  let liveTint = glass.tintColor,
                  let storedTint = GlassMaterialColorValue(liveTint),
                  Self.color(storedTint, matches: color.colorValue),
                  let tintLayer =
                    GlassMaterialAccess.tintMatrixLayer(under: glass),
                  let matrix = GlassMaterialAccess.colorMatrix(on: tintLayer)
            else {
                previousMatrix = nil
                stableReadCount = 0
                continue
            }
            if previousMatrix == matrix {
                stableReadCount += 1
            } else {
                previousMatrix = matrix
                stableReadCount = 1
            }
            if stableReadCount >= 2 {
                return (glass, tintLayer, matrix, storedTint)
            }
        }
        throw GlassLabTintRenderedABError.contextRejected(
            "\(GlassLabTintSweepCell(cell).label) · \(color.label)"
        )
    }

    nonisolated private static func maximumDifference(
        _ lhs: [Float],
        _ rhs: [Float]
    ) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        return zip(lhs, rhs).map {
            abs(Double($0) - Double($1))
        }.max() ?? 0
    }

    nonisolated private static func color(
        _ lhs: GlassMaterialColorValue,
        matches rhs: GlassMaterialColorValue
    ) -> Bool {
        let tolerance = 0.000001
        return abs(lhs.red - rhs.red) <= tolerance
            && abs(lhs.green - rhs.green) <= tolerance
            && abs(lhs.blue - rhs.blue) <= tolerance
            && abs(lhs.alpha - rhs.alpha) <= tolerance
    }
}
#endif
