//
//  GlassLabGoldenExport.swift
//  LiquidGlassLab
//
//  Drives the canonical Static Snapshot and Dynamic capture plan.
//
//  One command produces every section, because the sections have to agree on
//  their environment to be comparable. Capturing them separately is how the
//  previous archive ended up with two OS builds filed under one directory and
//  a static sweep whose appearance nobody recorded.
//

#if os(macOS)
import AppKit
import Foundation
import SwiftUI

enum GlassLabGoldenExportError: LocalizedError {
    case contextRejected(context: String, detail: String)
    case emptySection(String)
    case duplicateRow(section: String, cell: String)
    case unprojectableCatalog(cell: String)
    case promotionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .contextRejected(context, detail):
            "Static context \(context) could not be captured: \(detail)."
        case let .emptySection(section):
            "Section \(section) captured no rows; the archive was not written."
        case let .duplicateRow(section, cell):
            "Section \(section) produced an unintended duplicate at \(cell). "
                + "This section does not permit repeated cells."
        case let .unprojectableCatalog(cell):
            "Static context \(cell) is required by Consumer but cannot project "
                + "a complete supported style sample."
        case let .promotionFailed(detail):
            "Golden staging could not be promoted atomically: \(detail)"
        }
    }
}

extension GlassLabView {
    // MARK: - Entry point

    func exportGoldenArchive() {
        guard !state.hasActiveOverrides else {
            state.reportOutput =
                "Disable Override before capturing a Golden archive."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Capture"
        panel.message = "Choose a directory for the Static and Dynamic capture."
        guard panel.runModal() == .OK, let base = panel.url else { return }

        isCapturingMatrix = true
        matrixCaptureTask = Task { @MainActor in
            defer {
                isCapturingMatrix = false
                matrixCaptureTask = nil
            }
            do {
                let meta = try await captureGoldenArchive(
                    into: base.appendingPathComponent("unified", isDirectory: true)
                )
                state.reportOutput = Self.goldenReport(meta)
            } catch is CancellationError {
                state.reportOutput = "Golden capture cancelled; nothing was written."
            } catch {
                state.reportOutput = "Golden capture failed: "
                    + (error.localizedDescription)
            }
        }
    }

    /// Reports what the plan will capture, without capturing anything. The plan
    /// is data, so its row counts and swept axes are knowable before a single
    /// window is created — which is the cheapest possible time to notice that a
    /// slice collides with the core product or sweeps nothing.
    static func goldenPlanReport() -> String {
        var lines = ["== Golden core capture plan =="]
        let staticContexts = GlassLabGoldenPlan.staticContexts()
        let repeated = staticContexts.count - Set(staticContexts.map(\.cell.identity)).count
        lines.append(
            "static: \(staticContexts.count) unique observations, "
                + "\(GlassLabGoldenPlan.catalogContexts().count) Consumer anchors"
                + (repeated > 0 ? ", \(repeated) duplicate coordinates" : "")
        )
        var labels: [String: Int] = [:]
        for context in staticContexts { labels[context.label, default: 0] += 1 }
        for (label, count) in labels.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(label)  \(count) observations")
        }
        lines.append(
            "drift: \(GlassLabGoldenPlan.driftContexts().count) sentinel observations"
        )

        let dynamic = GlassLabGoldenPlan.dynamicContexts()
        var dynamicSlices: [String: Int] = [:]
        for context in dynamic { dynamicSlices[context.slice, default: 0] += 2 }
        lines.append(
            "dynamic: \(dynamic.count) contexts, \(dynamic.count * 2) runs, "
            + "\(dynamic.count * 2 * 9) samples"
        )
        for (slice, runs) in dynamicSlices.sorted(by: { $0.key < $1.key }) {
            lines.append(
                "  \(slice.padding(toLength: 13, withPad: " ", startingAt: 0))"
                + " \(runs) runs"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func goldenReport(_ summary: GoldenCaptureSummary) -> String {
        [
            "== Golden capture ==",
            "Static: \(summary.staticObservations) observations",
            "Dynamic: \(summary.dynamicRuns) runs",
            "OS: \(summary.capture.operatingSystem)",
            "Architecture: \(summary.capture.architecture)",
            "Display: \(summary.capture.displaySignature)",
        ].joined(separator: "\n")
    }

    // MARK: - Driver

    func captureGoldenArchive(into directory: URL) async throws -> GoldenCaptureSummary {
        try await captureGolden(
            into: directory,
            staticContexts: GlassLabGoldenPlan.staticContexts(),
            capturesDynamic: true
        )
    }

    func captureGoldenDriftArchive(
        into directory: URL
    ) async throws -> GoldenCaptureSummary {
        try await captureGolden(
            into: directory,
            staticContexts: GlassLabGoldenPlan.driftContexts(),
            capturesDynamic: false
        )
    }

    private func captureGolden(
        into directory: URL,
        staticContexts: [GlassLabGoldenPlan.StaticContext],
        capturesDynamic: Bool
    ) async throws -> GoldenCaptureSummary {
        let originalRenderer = state.rendererMode
        let originalUsage = state.semanticUsage
        let originalSemanticPage = selectedSemanticPage
        let originalAnimationMode = materializeAnimationMode
        let originalAnimationDuration = materializeLinearDuration
        let originalVisibility = state.isTestWindowVisible
        let originalMain = state.isTestWindowMain
        let originalKey = state.isTestWindowKey
        let originalSubdued = state.isSubdued
        let originalScrim = state.hasScrim
        let originalReducedTint = state.hasReducedTintOpacity
        let originalAdaptive = state.adaptiveAppearance
        let originalTint = state.tintColor
        let originalWidth = state.glassWidth
        let originalHeight = state.glassHeight
        let originalRadius = state.cornerRadius
        let originalHost = state.windowHostType
        let originalAppearance = state.testAppearance
        let originalBackdrop = state.testBackdrop
        let originalPadding = state.windowPadding
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled,
            ],
            reason: "Capturing the unified Golden archive"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            state.rendererMode = originalRenderer
            state.semanticUsage = originalUsage
            selectedSemanticPage = originalSemanticPage
            materializeAnimationMode = originalAnimationMode
            materializeLinearDuration = originalAnimationDuration
            state.isTestWindowKey = originalKey
            state.windowHostType = originalHost
            state.testAppearance = originalAppearance
            state.testBackdrop = originalBackdrop
            state.windowPadding = originalPadding
            restoreTestWindowContext(
                visibility: originalVisibility,
                isMainWindow: originalMain,
                isSubdued: originalSubdued,
                hasScrim: originalScrim,
                hasReducedTintOpacity: originalReducedTint,
                adaptiveAppearance: originalAdaptive,
                tintColor: originalTint,
                glassWidth: originalWidth,
                glassHeight: originalHeight,
                cornerRadius: originalRadius
            )
            configureSemanticTransitionProbe()
        }

        // Static product and research requirements share one canonical physical
        // context and one complete typed tree per coordinate.
        let appearance = GlassLabGoldenPlan.staticAppearance
        state.hasScrim = false
        state.hasReducedTintOpacity = false
        state.adaptiveAppearance = 2
        state.tintColor = nil
        state.testAppearance = appearance
        state.testBackdrop = GlassLabGoldenPlan.staticBackdrop
        state.windowPadding = GlassLabGoldenPlan.staticWindowPadding
        state.isTestWindowKey = false
        let capturedAt = ISO8601DateFormatter().string(from: Date())
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString

        // Scoped to Static, and deliberately not held across the
        // dynamic one. The flag stops the Recipe host and live readout from
        // reacting while the static sweeps stamp each context themselves.
        // The dynamic section uses the independent semantic host and should
        // run through the same normal observation path as the accepted
        // Materialize studies it is meant to replace.
        state.isCapturingRecipeMatrix = true
        let staticDocument = try await captureStaticSection(
            contexts: staticContexts
        )
        state.isCapturingRecipeMatrix = false
        let dynamic = capturesDynamic ? try await captureDynamicSection() : nil

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let capture = GoldenCaptureDocument(
            schemaVersion: goldenSchemaVersion,
            operatingSystem: operatingSystem,
            architecture: architecture,
            displaySignature: GlassMaterialStyleAtlas.Environment.current(
                for: state.testWindow.liveWindow?.screen
            ).displaySignature,
            capturedAt: capturedAt
        )

        return try Self.writeGoldenArchive(
            into: directory,
            capture: capture,
            staticDocument: staticDocument,
            dynamic: dynamic
        )
    }

    // MARK: - Static context settling

    /// Rebuilds and settles one exact coordinate. All 16 polls observe the same
    /// fresh glass; failure after five bounded attempts aborts the whole archive.
    private func captureStaticSnapshot(
        _ context: GlassLabGoldenPlan.StaticContext,
        progress: String
    ) async throws -> GoldenResolvedSnapshot {
        for _ in 1...5 {
            try Task.checkCancellation()
            try await waitUntilApplicationIsActive(progress: progress)

            state.rendererMode = .recipe
            state.windowHostType = context.host
            state.testAppearance = context.appearance
            state.testBackdrop = GlassLabGoldenPlan.staticBackdrop
            state.windowPadding = GlassLabGoldenPlan.staticWindowPadding
            state.hasScrim = false
            state.hasReducedTintOpacity = false
            state.adaptiveAppearance = 2
            state.tintColor = nil
            state.glassWidth = context.width
            state.glassHeight = context.height
            state.cornerRadius = context.cornerRadius
            state.variant = context.variant
            state.subvariant = context.subvariant ?? ""
            state.isTestWindowMain = context.main
            state.isTestWindowKey = context.key
            state.isSubdued = context.subdued
            state.isTestWindowVisible = true
            state.testWindow.sync(with: state)
            state.testWindow.rebuildGlass(with: state)
            guard let glass = state.testWindow.liveGlass else {
                try await Task.sleep(for: .milliseconds(180))
                continue
            }
            GlassLabTuning.applyRecipe(from: state, to: glass)
            try await Task.sleep(for: .milliseconds(700))

            guard NSApp.isActive else { continue }
            guard state.testWindow.isActuallyMain == context.main,
                  state.testWindow.isActuallyKey == context.key,
                  context.appearance.matchesName(
                      state.testWindow.effectiveAppearanceName ?? ""
                  ) else {
                continue
            }
            do {
                let snapshot = try await GlassLabTuning.settledResolvedTreeSnapshot(
                    from: glass
                )
                let actualKey = glass.window.map { NSApp.keyWindow === $0 } ?? false
                let actualMain = glass.window.map { NSApp.mainWindow === $0 } ?? false
                guard NSApp.isActive else { continue }
                guard actualMain == context.main, actualKey == context.key,
                      context.appearance.matchesName(
                          state.testWindow.effectiveAppearanceName ?? ""
                      ) else {
                    continue
                }
                return snapshot
            } catch GlassLabTuning.MatrixCaptureError.applicationInactive {
                continue
            } catch GlassLabTuning.MatrixCaptureError.missingLayerTree {
                continue
            } catch GlassLabTuning.MatrixCaptureError.unstableResolvedTree {
                continue
            }
        }
        throw GlassLabGoldenExportError.contextRejected(
            context: context.cell.identity,
            detail: "five fresh rebuilds exhausted before a stable complete tree "
                + "matched main=\(context.main), key=\(context.key), and "
                + "appearance=\(context.appearance.rawValue)"
        )
    }

    // MARK: - Static

    private func captureStaticSection(
        contexts: [GlassLabGoldenPlan.StaticContext]
    ) async throws -> GoldenStaticDocument {
        var observations: [GoldenStaticObservation] = []

        for (index, context) in contexts.enumerated() {
            let snapshot = try await captureStaticSnapshot(
                context,
                progress: "static \(index + 1)/\(contexts.count) "
                    + "(\(context.label))"
            )
            if context.requiresCatalog,
               GlassLabTuning.styleSampleProjection(of: snapshot) == nil {
                throw GlassLabGoldenExportError.unprojectableCatalog(
                    cell: context.cell.identity
                )
            }
            observations.append(GoldenStaticObservation(
                cell: context.cell,
                snapshot: snapshot
            ))
            state.reportOutput = "Golden static: \(observations.count)/"
                + "\(contexts.count) observations."
        }

        guard !observations.isEmpty else {
            throw GlassLabGoldenExportError.emptySection("static")
        }
        return GoldenStaticDocument(
            schemaVersion: goldenSchemaVersion,
            consumerCells: contexts.filter(\.requiresCatalog).map(\.cell),
            observations: observations
        )
    }

    // MARK: - Dynamic

    private func captureDynamicSection() async throws -> GoldenDynamicDocument {
        let contexts = GlassLabGoldenPlan.dynamicContexts()
        var runs: [GoldenDynamicRun] = []

        state.rendererMode = .semanticUsage
        selectedSemanticPage = .transition
        materializeAnimationMode = .linear
        materializeLinearDuration = 1
        configureSemanticTransitionProbe()

        for (index, context) in contexts.enumerated() {
            for usage in [GlassLabSemanticUsage.regular, .clear] {
                try Task.checkCancellation()
                let preset: GlassLabTintPreset = context.tinted ? .coral50 : .none
                state.reportOutput = "Golden dynamic: run \(runs.count + 1), "
                    + "context \(index + 1)/\(contexts.count) (\(context.slice))."
                let capture = try await performMaterializeCapture(
                    usage: usage,
                    direction: context.direction,
                    animationMode: GlassLabMaterializeAnimationMode.linear,
                    linearDuration: 1,
                    requestedMain: context.main,
                    tint: preset.descriptor,
                    tintColor: preset.color,
                    appearance: context.appearance,
                    backdrop: context.backdrop,
                    glassSize: CGSize(
                        width: GlassLabGoldenPlan.referenceWidth,
                        height: context.shortSide
                    )
                )
                runs.append(GoldenDynamicRun(capture: capture, slice: context.slice))
            }
        }

        guard !runs.isEmpty else {
            throw GlassLabGoldenExportError.emptySection("dynamic")
        }
        return GoldenDynamicDocument(
            schemaVersion: goldenSchemaVersion,
            runs: runs
        )
    }

    // MARK: - Writing

    private static func writeGoldenArchive(
        into directory: URL,
        capture: GoldenCaptureDocument,
        staticDocument: GoldenStaticDocument,
        dynamic: GoldenDynamicDocument?
    ) throws -> GoldenCaptureSummary {
        let fileManager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        for candidate in (try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        )) ?? [] where candidate.lastPathComponent.hasPrefix(
            ".\(directory.lastPathComponent).staging-"
        ) {
            try? fileManager.removeItem(at: candidate)
        }
        let staging = parent.appendingPathComponent(
            ".\(directory.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: staging) }

        try writeGoldenArchivePayload(
            into: staging,
            capture: capture,
            staticDocument: staticDocument,
            dynamic: dynamic
        )
        do {
            if fileManager.fileExists(atPath: directory.path) {
                _ = try fileManager.replaceItemAt(
                    directory,
                    withItemAt: staging,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: staging, to: directory)
            }
        } catch {
            throw GlassLabGoldenExportError.promotionFailed(
                error.localizedDescription
            )
        }
        return GoldenCaptureSummary(
            capture: capture,
            staticObservations: staticDocument.observations.count,
            dynamicRuns: dynamic?.runs.count ?? 0
        )
    }

    private static func writeGoldenArchivePayload(
        into directory: URL,
        capture: GoldenCaptureDocument,
        staticDocument: GoldenStaticDocument,
        dynamic: GoldenDynamicDocument?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        try write(
            staticDocument,
            rows: staticDocument.observations.map(\.cell),
            named: "static",
            into: directory,
            encoder: encoder,
            allowsRepeats: false
        )
        if let dynamic {
            try write(
                dynamic,
                rows: dynamic.runs.map(\.cell),
                named: "dynamic",
                into: directory,
                encoder: encoder,
                allowsRepeats: true
            )
        }
        try write(
            capture,
            rows: [],
            named: "capture",
            into: directory,
            encoder: encoder,
            allowsRepeats: false
        )
    }

    private static func write<Document: Encodable>(
        _ document: Document,
        rows: [GoldenCell],
        named name: String,
        into directory: URL,
        encoder: JSONEncoder,
        allowsRepeats: Bool
    ) throws {
        let identities = rows.map(\.identity)
        let repeated = identities.count - Set(identities).count
        if !allowsRepeats, repeated > 0 {
            var seen = Set<String>()
            let offender = identities.first { !seen.insert($0).inserted } ?? "?"
            throw GlassLabGoldenExportError.duplicateRow(
                section: name, cell: offender
            )
        }

        var bytes = try encoder.encode(document)
        bytes.append(0x0A)
        let file = "\(name).json"
        try bytes.write(
            to: directory.appendingPathComponent(file),
            options: .atomic
        )

    }
}
#endif
