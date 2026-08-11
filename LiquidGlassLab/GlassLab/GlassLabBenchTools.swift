//
//  GlassLabBenchTools.swift
//  LiquidGlassLab
//
//  Bench: report copy and JSON export tools — recipe matrix, recursive
//  pass audit, semantic usage trees — with their completeness validators
//  and the shared test-window context restore.
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension GlassLabView {
    /// The Bench Exports page: the report/JSON exports that used to sit in a
    /// "Diagnostics" section on both General tweaking pages. Exports capture
    /// through the renderer they name, so the page carries its own renderer
    /// picker instead of inheriting whatever the tweaking side last used.
    @ViewBuilder
    func benchExportSections(state labState: GlassLabState) -> some View {
        @Bindable var state = labState

        Section("Exports") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Renderer", selection: $state.rendererMode) {
                    ForEach(GlassLabRendererMode.allCases) { mode in
                        Text(mode.navigationTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("Each export drives the selected renderer's test window through its own capture contexts and restores the previous context when it finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if state.rendererMode == .recipe {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Copy Glass Report") { copyReport() }
                    Button(
                        isCapturingMatrix
                            ? "Capturing…"
                            : "Capture Core Golden Modules (Atomic)"
                    ) {
                        exportGoldenArchive()
                    }
                    .disabled(isCapturingMatrix)
                    Button("Show Full / Drift Registry") {
                        state.reportOutput = Self.goldenRegistryReport()
                    }
                    Text("The core driver stages static-scalar, static-tree, dynamic, and meta, validates completeness, then atomically replaces unified/. It is one driver inside Full Golden, not the whole Full profile: Full also requires Tint and Semantic modules. Drift Scan is explicitly noncanonical and cannot be promoted.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Copy Semantic Report") { copySemanticReport() }
                            .disabled(semanticSnapshot == nil)
                        Button(
                            isCapturingSemanticTrees
                                ? "Capturing…"
                                : "Export All Usage Trees (JSON)"
                        ) {
                            exportSemanticUsageTrees()
                        }
                        .disabled(isCapturingSemanticTrees)
                    }
                    Text("The report copies the current live tree. Export walks every runtime Usage across Main Off/On at the current Size, Host, Corner Radius, and Window Margin, recording 48 availability/context rows, layers, CAFilter inputs, and object-backed SDF effects in a separate semantic-usage-trees.json file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !state.reportOutput.isEmpty {
                ScrollView {
                    Text(state.reportOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 180)
            }
        }
    }

    enum MatrixExportError: LocalizedError {
        case participationRejected(main: Bool, subdued: Bool, height: Double)
        case invalidMatrix(String)

        var errorDescription: String? {
            switch self {
            case let .participationRejected(main, subdued, height):
                "Panel/Window could not hold Main \(main ? "On" : "Off"), "
                    + "Subdued \(subdued ? "On" : "Off") at 480×\(height)."
            case let .invalidMatrix(reason):
                reason
            }
        }
    }

    enum SemanticExportError: LocalizedError {
        case missingSnapshot(String)
        case participationRejected(usage: String, requestedMain: Bool)
        case invalidEntryCount(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case let .missingSnapshot(usage):
                "\(usage) is available but produced no inspectable layer tree."
            case let .participationRejected(usage, requestedMain):
                "\(usage) could not hold Main \(requestedMain ? "On" : "Off") in the fixed export context."
            case let .invalidEntryCount(expected, actual):
                "Semantic export expected \(expected) entries but captured \(actual)."
            }
        }
    }

    func copyReport() {
        guard let glass = selectedReadoutGlass else {
            state.reportOutput = "The test window is unavailable — turn on Show Test Window first."
            return
        }
        let window = glass.window
        let actualKey = window.map { NSApp.keyWindow === $0 } ?? false
        let actualMain = window.map { NSApp.mainWindow === $0 } ?? false
        let header = "== \(state.windowHostType.rawValue) glass =="
            + " requestedMain=\(state.isTestWindowMain)"
            + " reportedKey=\(window?.isKeyWindow ?? false)"
            + " actualKey=\(actualKey)"
            + " reportedMain=\(window?.isMainWindow ?? false)"
            + " actualMain=\(actualMain)"
            + " appActive=\(NSApp.isActive)"
            + " appearance=\(window?.effectiveAppearance.name.rawValue ?? "?")"
        let report = GlassLabTuning.diagnosticsReport(for: glass, header: header)
        state.reportOutput = report
        copyToPasteboard(report)
    }

    func copyPassInventoryReport() {
        guard let snapshot = passInventorySnapshot else {
            state.reportOutput = "The Recipe surface has no recursive pass inventory yet."
            return
        }
        let header = "== \(state.windowHostType.rawValue) recursive pass inventory =="
            + " requestedMain=\(state.isTestWindowMain)"
            + " actualKey=\(state.testWindow.isActuallyKey)"
            + " actualMain=\(state.testWindow.isActuallyMain)"
            + " appActive=\(NSApp.isActive)"
            + " variant=\(state.variant)"
            + " subvariant=\(state.subvariant.isEmpty ? "<nil>" : state.subvariant)"
            + " subdued=\(state.isSubdued)"
        let passStates = Dictionary(uniqueKeysWithValues: passInventoryItems(snapshot).map {
            ($0.record.id, passState(for: $0, state: state))
        })
        let report = GlassLabTuning.passAuditReport(
            snapshot,
            header: header,
            passStates: passStates
        )
        state.reportOutput = report
        copyToPasteboard(report)
    }

    func copySemanticReport() {
        guard let snapshot = semanticSnapshot else {
            state.reportOutput = "The Semantic surface is unavailable — show the test window and select a supported Usage first."
            return
        }
        let window = state.testWindow.liveWindow
        let header = "== \(state.windowHostType.rawValue) semantic glass =="
            + " usage=\(state.semanticUsage.displayName)"
            + " swiftUIRoleTag=\(state.semanticUsage.rawValue)"
            + " requestedMain=\(state.isTestWindowMain)"
            + " actualKey=\(state.testWindow.isActuallyKey)"
            + " actualMain=\(state.testWindow.isActuallyMain)"
            + " appActive=\(NSApp.isActive)"
            + " appearance=\(window?.effectiveAppearance.name.rawValue ?? "?")"
        let report = header + "\n" + snapshot.report
        state.reportOutput = report
        copyToPasteboard(report)
    }

    func exportSemanticUsageTrees() {
        guard state.rendererMode == .semanticUsage else {
            state.reportOutput = "Switch Renderer to Semantic Usage before exporting Usage trees."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "semantic-usage-trees.json"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        liveRefreshTask?.cancel()
        isCapturingSemanticTrees = true
        semanticCaptureTask = Task { @MainActor in
            let captureStartedAt = Date()
            defer {
                isCapturingSemanticTrees = false
                semanticCaptureTask = nil
                scheduleLiveReadoutRefresh()
            }

            do {
                let document = try await captureSemanticUsageTreesDocument()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(document)
                try data.write(to: destinationURL, options: .atomic)
                let availableCount = document.entries.filter(\.isAvailable).count
                let capturedCount = document.entries.count {
                    $0.snapshot != nil
                }
                let duration = Date().timeIntervalSince(captureStartedAt)
                state.reportOutput = "Exported \(capturedCount)/\(availableCount) available "
                    + "Semantic Usage × Main trees (\(document.entries.count) entries) in "
                    + "\(String(format: "%.1f", duration)) seconds to "
                    + destinationURL.path
            } catch is CancellationError {
                state.reportOutput = "Semantic Usage Tree capture cancelled; no file was written."
            } catch {
                state.reportOutput = "Semantic Usage Tree capture failed; no file was written.\n"
                    + error.localizedDescription
            }
        }
    }

    @MainActor
    func captureSemanticUsageTreesDocument() async throws
        -> GlassLabSemanticTreeExport
    {
        let originalUsage = state.semanticUsage
        let originalMainState = state.isTestWindowMain
        let originalVisibility = state.isTestWindowVisible
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Capturing Semantic Glass Usage Trees"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            state.semanticUsage = originalUsage
            state.isTestWindowMain = originalMainState
            state.isTestWindowVisible = originalVisibility
            state.testWindow.sync(with: state)
        }
        if !state.isTestWindowVisible {
            state.isTestWindowVisible = true
            state.testWindow.sync(with: state)
        }

        var entries: [GlassLabSemanticTreeEntry] = []
        let usages = GlassLabSemanticUsage.allCases
        let mainStates = [false, true]
        let expectedEntryCount = usages.count * mainStates.count
        var captureIndex = 0
        for requestedMain in mainStates {
            state.isTestWindowMain = requestedMain
            state.testWindow.sync(with: state)
            for usage in usages {
                captureIndex += 1
                let progress = "Semantic Usage \(captureIndex)/\(expectedEntryCount)"
                    + " · Main \(requestedMain ? "On" : "Off")"
                    + " · \(usage.displayName)"
                try await waitUntilApplicationIsActive(progress: progress)
                let runtime = GlassLabSemanticRuntime.shared
                let isAvailable = runtime.isAvailable(usage)
                let runtimeStatus = runtime.status(for: usage)
                state.isTestWindowMain = requestedMain
                if isAvailable { state.semanticUsage = usage }
                state.testWindow.sync(with: state)
                let snapshot = try await settleSemanticExportContext(
                    capturesSnapshot: isAvailable,
                    progress: progress
                )
                guard state.testWindow.isActuallyMain == requestedMain,
                      !state.testWindow.isActuallyKey else {
                    throw SemanticExportError.participationRejected(
                        usage: usage.displayName,
                        requestedMain: requestedMain
                    )
                }
                if isAvailable, snapshot == nil {
                    throw SemanticExportError.missingSnapshot(usage.displayName)
                }
                entries.append(GlassLabSemanticTreeEntry(
                    roleTag: usage.rawValue,
                    usage: usage.displayName,
                    requestedMain: requestedMain,
                    isAvailable: isAvailable,
                    runtimeStatus: runtimeStatus,
                    actualMain: state.testWindow.isActuallyMain,
                    actualKey: state.testWindow.isActuallyKey,
                    snapshot: snapshot
                ))
                state.reportOutput = "Captured \(progress)."
            }
        }
        guard entries.count == expectedEntryCount else {
            throw SemanticExportError.invalidEntryCount(
                expected: expectedEntryCount,
                actual: entries.count
            )
        }
        return GlassLabSemanticTreeExport(
            formatVersion: 2,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            axes: .init(requestedMain: mainStates, roleTags: usages.map(\.rawValue)),
            context: .init(
                hostType: state.windowHostType.rawValue,
                glassWidth: state.glassWidth,
                glassHeight: state.glassHeight,
                cornerRadius: state.cornerRadius,
                windowMargin: state.windowPadding
            ),
            entries: entries
        )
    }

    @MainActor
    func settleSemanticExportContext(
        capturesSnapshot: Bool,
        progress: String
    ) async throws -> GlassLabSemanticSnapshot? {
        var snapshot = try await settleSemanticRender(
            capturesSnapshot: capturesSnapshot
        )

        // AppKit drops real main participation when the app deactivates.
        // Resume only after activation, then resolve the exact requested
        // Main-only or neither context again before accepting the row.
        if !NSApp.isActive {
            try await waitUntilApplicationIsActive(
                progress: "Retrying \(progress) after activation"
            )
            state.testWindow.sync(with: state)
            snapshot = try await settleSemanticRender(
                capturesSnapshot: capturesSnapshot
            )
        }

        if state.testWindow.isActuallyMain != state.isTestWindowMain
            || state.testWindow.isActuallyKey {
            state.testWindow.sync(with: state)
            snapshot = try await settleSemanticRender(
                capturesSnapshot: capturesSnapshot
            )
        }
        return snapshot
    }

    @MainActor
    func settleSemanticRender(capturesSnapshot: Bool) async throws
        -> GlassLabSemanticSnapshot? {
        if capturesSnapshot {
            return try await captureSettledSemanticSnapshot()
        }
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        return nil
    }

    @MainActor
    func captureSettledSemanticSnapshot() async throws
        -> GlassLabSemanticSnapshot? {
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        state.testWindow.liveWindow?.contentView?.layoutSubtreeIfNeeded()
        state.testWindow.liveWindow?.contentView?.displayIfNeeded()
        if let snapshot = GlassLabSemanticSnapshot.capture(
            from: state.testWindow.liveSemanticLayerRoot
        ) {
            return snapshot
        }

        // A newly created NSHostingView can need one extra run-loop/render
        // pass before it owns a root layer. This retry is only for absence;
        // normal Usage traversal pays the same 180 ms used by the original
        // direct SwiftUI probe.
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        state.testWindow.liveWindow?.contentView?.layoutSubtreeIfNeeded()
        state.testWindow.liveWindow?.contentView?.displayIfNeeded()
        return GlassLabSemanticSnapshot.capture(
            from: state.testWindow.liveSemanticLayerRoot
        )
    }

    func waitUntilApplicationIsActive(progress: String) async throws {
        var reportedPause = false
        while !NSApp.isActive {
            if !reportedPause {
                state.reportOutput = progress
                    + "\nPaused while the app is inactive. Return to Liquid Glass Lab to resume."
                reportedPause = true
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()
    }

    func restoreTestWindowContext(
        visibility: Bool,
        isMainWindow: Bool,
        isSubdued: Bool,
        hasScrim: Bool,
        hasReducedTintOpacity: Bool,
        adaptiveAppearance: Int,
        tintColor: NSColor?,
        glassWidth: Double,
        glassHeight: Double,
        cornerRadius: Double
    ) {
        state.isTestWindowMain = isMainWindow
        state.isSubdued = isSubdued
        state.hasScrim = hasScrim
        state.hasReducedTintOpacity = hasReducedTintOpacity
        state.adaptiveAppearance = adaptiveAppearance
        state.tintColor = tintColor
        state.glassWidth = glassWidth
        state.glassHeight = glassHeight
        state.cornerRadius = cornerRadius
        state.isTestWindowVisible = visibility
        state.isCapturingRecipeMatrix = false
        state.testWindow.sync(with: state)
        scheduleLiveReadoutRefresh(refreshSchema: true)
        isCapturingMatrix = false
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
#endif
