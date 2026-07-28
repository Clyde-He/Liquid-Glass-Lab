//
//  GlassLabGoldenExport.swift
//  LiquidGlassLab
//
//  Drives the capture plan and writes the unified Golden archive.
//
//  One command produces every section, because the sections have to agree on
//  their environment to be comparable. Capturing them separately is how the
//  previous archive ended up with two OS builds filed under one directory and
//  a static sweep whose appearance nobody recorded.
//

#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import SwiftUI

enum GlassLabGoldenExportError: LocalizedError {
    case contextRejected(slice: String, detail: String)
    case emptySection(String)
    case duplicateRow(section: String, cell: String)

    var errorDescription: String? {
        switch self {
        case let .contextRejected(slice, detail):
            "The \(slice) slice could not establish its context: \(detail)."
        case let .emptySection(section):
            "Section \(section) captured no rows; the archive was not written."
        case let .duplicateRow(section, cell):
            "Section \(section) produced an unintended duplicate at \(cell). "
                + "Only the dynamic overlap may repeat a cell."
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
        panel.message = "Choose the OS directory to write unified/ into."
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
        var lines = ["== Golden capture plan =="]

        func summarize(
            _ title: String,
            _ contexts: [GlassLabGoldenPlan.StaticContext]
        ) {
            var perSlice: [String: (contexts: Int, rows: Int)] = [:]
            var identities: [String] = []
            for context in contexts {
                let rows = context.sweepsEveryVariant
                    ? GlassLabTuning.variants.count
                        * (GlassLabTuning.knownSubvariants.count + 1)
                    : (context.variants?.count ?? 0)
                perSlice[context.slice, default: (0, 0)].contexts += 1
                perSlice[context.slice, default: (0, 0)].rows += rows
                let subvariants: [String?] = context.sweepsEveryVariant
                    ? [nil] + GlassLabTuning.knownSubvariants.map(Optional.some)
                    : [nil]
                for variant in context.variants ?? GlassLabTuning.variants {
                    for subvariant in subvariants {
                        identities.append(GoldenCell.staticCell(
                            variant: variant,
                            subvariant: subvariant,
                            context: context,
                            appearance: .light
                        ).identity)
                    }
                }
            }
            let total = perSlice.values.reduce(0) { $0 + $1.rows }
            let repeated = identities.count - Set(identities).count
            lines.append(
                "\(title): \(contexts.count) contexts, \(total) rows"
                + (repeated > 0 ? ", \(repeated) repeated cells" : "")
            )
            for (slice, counts) in perSlice.sorted(by: { $0.key < $1.key }) {
                lines.append(
                    "  \(slice.padding(toLength: 13, withPad: " ", startingAt: 0))"
                    + " \(counts.contexts) contexts  \(counts.rows) rows"
                )
            }
        }

        summarize("static-scalar", GlassLabGoldenPlan.staticContexts())
        summarize("static-tree", GlassLabGoldenPlan.treeContexts())

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

    static func goldenReport(_ meta: GoldenMeta) -> String {
        var lines = ["== Golden archive =="]
        for name in ["static-scalar", "static-tree", "dynamic"] {
            guard let section = meta.sections[name] else { continue }
            let megabytes = Double(section.bytes) / 1_048_576
            let slices = section.slices
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            lines.append(
                "\(name.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                + "\(section.rows) rows  \(String(format: "%.1f", megabytes)) MB"
                + (section.repeatedCells > 0
                    ? "  \(section.repeatedCells) repeated"
                    : "")
            )
            lines.append("  slices: \(slices)")
            lines.append("  swept: \(section.swept.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Driver

    func captureGoldenArchive(into directory: URL) async throws -> GoldenMeta {
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
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled,
            ],
            reason: "Capturing the unified Golden archive"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            state.isTestWindowKey = originalKey
            state.windowHostType = originalHost
            state.testAppearance = originalAppearance
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
        }

        // The static sections are captured under one explicit appearance so a
        // settled dynamic sample can be paired against its static endpoint.
        // The historical sweeps recorded whatever the machine happened to be
        // in, which is why that comparison was never expressible.
        let appearance = GlassLabTestAppearance.light
        let environment = GoldenEnvironment(
            windowMargin: 40,
            scrim: false,
            reducedTintOpacity: false,
            adaptiveAppearance: 2,
            overridesEnabled: false
        )
        let capturedAt = ISO8601DateFormatter().string(from: Date())
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString

        let scalar = try await captureStaticScalarSection(
            appearance: appearance,
            environment: environment,
            capturedAt: capturedAt,
            operatingSystem: operatingSystem
        )
        let tree = try await captureStaticTreeSection(
            appearance: appearance,
            environment: environment,
            capturedAt: capturedAt,
            operatingSystem: operatingSystem
        )
        let dynamic = try await captureDynamicSection(
            environment: environment,
            capturedAt: capturedAt,
            operatingSystem: operatingSystem
        )

        return try Self.writeGoldenArchive(
            into: directory,
            capturedAt: capturedAt,
            operatingSystem: operatingSystem,
            scalar: scalar,
            tree: tree,
            dynamic: dynamic
        )
    }

    // MARK: - Static context settling

    /// Establishes one static context and runs `body` against the live glass,
    /// retrying the whole context when the application deactivates or AppKit
    /// moves participation mid-sweep. A partial batch is never retained: a
    /// half-swept context would look like a complete one to a reader.
    private func withStaticContext<Row>(
        _ context: GlassLabGoldenPlan.StaticContext,
        progress: String,
        body: (NSGlassEffectView, String) async throws -> [Row]
    ) async throws -> [Row] {
        var attempts = 0
        while true {
            try Task.checkCancellation()
            try await waitUntilApplicationIsActive(progress: progress)

            state.rendererMode = .recipe
            state.windowHostType = context.host
            state.testAppearance = GlassLabTestAppearance.light
            state.glassWidth = context.width
            state.glassHeight = context.height
            state.cornerRadius = context.cornerRadius
            state.isTestWindowMain = context.main
            state.isTestWindowKey = context.key
            state.isSubdued = context.subdued
            state.isTestWindowVisible = true
            state.testWindow.sync(with: state)
            if let glass = state.testWindow.liveGlass {
                GlassLabTuning.applyRecipe(from: state, to: glass)
            }
            try await Task.sleep(for: .milliseconds(300))

            guard NSApp.isActive else { continue }
            guard state.testWindow.isActuallyMain == context.main,
                  state.testWindow.isActuallyKey == context.key,
                  let glass = state.testWindow.liveGlass else {
                attempts += 1
                guard attempts < 4 else {
                    throw GlassLabGoldenExportError.contextRejected(
                        slice: context.slice,
                        detail: "wanted main=\(context.main) key=\(context.key), "
                            + "got main=\(state.testWindow.isActuallyMain) "
                            + "key=\(state.testWindow.isActuallyKey)"
                    )
                }
                continue
            }

            let label = "\(context.host.contextID)-\(context.slice)"
                + (context.key ? "-key" : (context.main ? "-main" : "-neither"))
                + (context.subdued ? "-subdued" : "-standard")
            do {
                return try await body(glass, label)
            } catch GlassLabTuning.MatrixCaptureError.applicationInactive {
                continue
            } catch GlassLabTuning.MatrixCaptureError.participationChanged {
                attempts += 1
                guard attempts < 4 else {
                    throw GlassLabGoldenExportError.contextRejected(
                        slice: context.slice,
                        detail: "participation changed during the sweep"
                    )
                }
                continue
            }
        }
    }

    // MARK: - Section 1

    private func captureStaticScalarSection(
        appearance: GlassLabTestAppearance,
        environment: GoldenEnvironment,
        capturedAt: String,
        operatingSystem: String
    ) async throws -> GoldenStaticScalarDocument {
        let contexts = GlassLabGoldenPlan.staticContexts()
        var rows: [GoldenStaticScalarRow] = []
        var capability: GoldenStaticScalarDocument.Capability?

        for (index, context) in contexts.enumerated() {
            let batch = try await withStaticContext(
                context,
                progress: "static-scalar \(index + 1)/\(contexts.count) "
                    + "(\(context.slice)) · \(rows.count) rows"
            ) { glass, label in
                try await GlassLabTuning.captureMatrix(
                    on: glass,
                    context: label,
                    requestedMain: context.main,
                    requestedKey: context.key,
                    subdued: context.subdued,
                    variants: context.variants,
                    restoring: state
                )
            }
            if capability == nil, let first = batch.first {
                capability = .init(
                    shaderInputKeys: first.shaderInputKeys,
                    highlightInputKeys: first.highlightInputKeys,
                    geometryKeys: first.geometryKeys
                )
            }
            rows += batch.map { entry in
                GoldenStaticScalarRow(
                    entry: entry,
                    cell: .staticCell(
                        variant: entry.variant,
                        subvariant: entry.subvariant,
                        context: context,
                        appearance: appearance
                    ),
                    slice: context.slice
                )
            }
            state.reportOutput = "Golden static-scalar: \(rows.count) rows, "
                + "context \(index + 1)/\(contexts.count)."
        }

        guard !rows.isEmpty else {
            throw GlassLabGoldenExportError.emptySection("static-scalar")
        }
        return GoldenStaticScalarDocument(
            schemaVersion: goldenSchemaVersion,
            section: "static-scalar",
            capturedAt: capturedAt,
            operatingSystem: operatingSystem,
            environment: environment,
            capability: capability ?? .init(
                shaderInputKeys: [], highlightInputKeys: [], geometryKeys: []
            ),
            rows: rows
        )
    }

    // MARK: - Section 2

    private func captureStaticTreeSection(
        appearance: GlassLabTestAppearance,
        environment: GoldenEnvironment,
        capturedAt: String,
        operatingSystem: String
    ) async throws -> GoldenStaticTreeDocument {
        let contexts = GlassLabGoldenPlan.treeContexts()
        var rows: [GoldenStaticTreeRow] = []

        for (index, context) in contexts.enumerated() {
            let batch = try await withStaticContext(
                context,
                progress: "static-tree \(index + 1)/\(contexts.count) "
                    + "(\(context.slice)) · \(rows.count) rows"
            ) { glass, label in
                try await GlassLabTuning.capturePassAudit(
                    on: glass,
                    context: label,
                    requestedMain: context.main,
                    requestedKey: context.key,
                    subdued: context.subdued,
                    variants: context.variants,
                    restoring: state
                )
            }
            rows += batch.map { entry in
                GoldenStaticTreeRow(
                    entry: entry,
                    cell: .staticCell(
                        variant: entry.variant,
                        subvariant: entry.subvariant,
                        context: context,
                        appearance: appearance
                    ),
                    slice: context.slice
                )
            }
            state.reportOutput = "Golden static-tree: \(rows.count) rows, "
                + "context \(index + 1)/\(contexts.count)."
        }

        guard !rows.isEmpty else {
            throw GlassLabGoldenExportError.emptySection("static-tree")
        }
        return GoldenStaticTreeDocument(
            schemaVersion: goldenSchemaVersion,
            section: "static-tree",
            capturedAt: capturedAt,
            operatingSystem: operatingSystem,
            environment: environment,
            rows: rows
        )
    }

    // MARK: - Section 3

    private func captureDynamicSection(
        environment: GoldenEnvironment,
        capturedAt: String,
        operatingSystem: String
    ) async throws -> GoldenDynamicDocument {
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
            section: "dynamic",
            capturedAt: capturedAt,
            operatingSystem: operatingSystem,
            environment: environment,
            runs: runs
        )
    }

    // MARK: - Writing

    private static func writeGoldenArchive(
        into directory: URL,
        capturedAt: String,
        operatingSystem: String,
        scalar: GoldenStaticScalarDocument,
        tree: GoldenStaticTreeDocument,
        dynamic: GoldenDynamicDocument
    ) throws -> GoldenMeta {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var sections: [String: GoldenMeta.Section] = [:]
        sections["static-scalar"] = try write(
            scalar,
            rows: scalar.rows.map(\.cell),
            slices: scalar.rows.map(\.slice),
            named: "static-scalar",
            into: directory,
            encoder: encoder,
            allowsRepeats: false
        )
        sections["static-tree"] = try write(
            tree,
            rows: tree.rows.map(\.cell),
            slices: tree.rows.map(\.slice),
            named: "static-tree",
            into: directory,
            encoder: encoder,
            // The repeat pass deliberately re-captures cells that already
            // exist; that overlap is the stability evidence.
            allowsRepeats: true
        )
        sections["dynamic"] = try write(
            dynamic,
            rows: dynamic.runs.map(\.cell),
            slices: dynamic.runs.map(\.slice),
            named: "dynamic",
            into: directory,
            encoder: encoder,
            allowsRepeats: true
        )

        let meta = GoldenMeta(
            schemaVersion: goldenSchemaVersion,
            operatingSystem: operatingSystem,
            capturedAt: capturedAt,
            role: "canonical",
            sections: sections
        )
        let metaEncoder = JSONEncoder()
        metaEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try metaEncoder.encode(meta).write(
            to: directory.appendingPathComponent("meta.json"),
            options: .atomic
        )
        return meta
    }

    private static func write<Document: Encodable>(
        _ document: Document,
        rows: [GoldenCell],
        slices: [String],
        named name: String,
        into directory: URL,
        encoder: JSONEncoder,
        allowsRepeats: Bool
    ) throws -> GoldenMeta.Section {
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

        var sliceCounts: [String: Int] = [:]
        for slice in slices { sliceCounts[slice, default: 0] += 1 }

        return GoldenMeta.Section(
            file: file,
            rows: rows.count,
            repeatedCells: repeated,
            bytes: bytes.count,
            sha256: SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }
                .joined(),
            swept: GoldenCell.sweptAxes(in: rows),
            slices: sliceCounts
        )
    }
}

extension GoldenCell {
    /// Axes that actually take more than one non-nil value. Recorded so a
    /// reader can tell "this axis was held constant" from "this axis was never
    /// controlled" without inspecting every row.
    static func sweptAxes(in cells: [GoldenCell]) -> [String] {
        var axes: [String] = []
        func check(_ name: String, _ values: [AnyHashable?]) {
            let distinct = Set(values.compactMap { $0 })
            if distinct.count > 1 { axes.append(name) }
        }
        check("variant", cells.map { $0.variant.map(AnyHashable.init) })
        check("subvariant", cells.map { $0.subvariant.map(AnyHashable.init) })
        check("main", cells.map { $0.main.map(AnyHashable.init) })
        check("key", cells.map { $0.key.map(AnyHashable.init) })
        check("subdued", cells.map { $0.subdued.map(AnyHashable.init) })
        check("appearance", cells.map { $0.appearance.map(AnyHashable.init) })
        check("backdrop", cells.map { $0.backdrop.map(AnyHashable.init) })
        check("tint", cells.map { $0.tint.map(AnyHashable.init) })
        check("width", cells.map { $0.width.map(AnyHashable.init) })
        check("height", cells.map { $0.height.map(AnyHashable.init) })
        check("cornerRadius", cells.map { $0.cornerRadius.map(AnyHashable.init) })
        check("host", cells.map { $0.host.map(AnyHashable.init) })
        check("direction", cells.map { $0.direction.map(AnyHashable.init) })
        return axes
    }
}
#endif
