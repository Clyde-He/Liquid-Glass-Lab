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
                    HStack {
                        Button("Copy Glass Report") { copyReport() }
                        Button(isCapturingMatrix ? "Capturing…" : "Export Recipe Matrix (JSON)") {
                            exportMatrix()
                        }
                        .disabled(isCapturingMatrix || isCapturingPassAudit)
                    }
                    Button(
                        isCapturingPassAudit
                            ? "Auditing…"
                            : "Export Recursive Pass Audit (JSON)"
                    ) {
                        exportPassAudit()
                    }
                    .disabled(isCapturingMatrix || isCapturingPassAudit)
                    Divider()
                    Button(
                        isCapturingMatrix
                            ? "Capturing…"
                            : "Capture Golden Archive (unified/)"
                    ) {
                        exportGoldenArchive()
                    }
                    .disabled(isCapturingMatrix || isCapturingPassAudit)
                    Text("Golden Archive replaces the two exports above. It writes unified/ as four files — static-scalar, static-tree, dynamic, and meta — in one run, so every section shares an environment and can be compared cell by cell. See Golden/CAPTURE-SPEC.md for what each slice exists to prove.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Recipe Matrix records 1,008 compact Shader/Rim rows across representative Heights. Recursive Pass Audit is a separate 336-row Panel capture at 480×200@16 and Margin 40; it walks sublayers, masks, filters, background filters, compositing filters, and object-backed effects across Main × Subdued × Variant × Subvariant. Both exports pause while the app is inactive and require clean system state with Overrides disabled.")
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
            let originalUsage = state.semanticUsage
            let originalMainState = state.isTestWindowMain
            let originalVisibility = state.isTestWindowVisible
            let captureStartedAt = Date()
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .userInitiated,
                    .idleSystemSleepDisabled,
                    .idleDisplaySleepDisabled,
                ],
                reason: "Capturing Semantic Glass Usage Trees"
            )

            defer {
                ProcessInfo.processInfo.endActivity(activity)
                state.semanticUsage = originalUsage
                state.isTestWindowMain = originalMainState
                state.isTestWindowVisible = originalVisibility
                state.testWindow.sync(with: state)
                isCapturingSemanticTrees = false
                semanticCaptureTask = nil
                scheduleLiveReadoutRefresh()
            }

            do {
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
                        var snapshot: GlassLabSemanticSnapshot?

                        state.isTestWindowMain = requestedMain
                        if isAvailable {
                            state.semanticUsage = usage
                        }
                        state.testWindow.sync(with: state)
                        snapshot = try await settleSemanticExportContext(
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

                        entries.append(
                            GlassLabSemanticTreeEntry(
                                roleTag: usage.rawValue,
                                usage: usage.displayName,
                                requestedMain: requestedMain,
                                isAvailable: isAvailable,
                                runtimeStatus: runtimeStatus,
                                actualMain: state.testWindow.isActuallyMain,
                                actualKey: state.testWindow.isActuallyKey,
                                snapshot: snapshot
                            )
                        )
                        state.reportOutput = "Captured \(progress)."
                    }
                }

                guard entries.count == expectedEntryCount else {
                    throw SemanticExportError.invalidEntryCount(
                        expected: expectedEntryCount,
                        actual: entries.count
                    )
                }

                let document = GlassLabSemanticTreeExport(
                    formatVersion: 2,
                    generatedAt: ISO8601DateFormatter().string(from: Date()),
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    axes: GlassLabSemanticTreeAxes(
                        requestedMain: mainStates,
                        roleTags: usages.map(\.rawValue)
                    ),
                    context: GlassLabSemanticTreeContext(
                        hostType: state.windowHostType.rawValue,
                        glassWidth: state.glassWidth,
                        glassHeight: state.glassHeight,
                        cornerRadius: state.cornerRadius,
                        windowMargin: state.windowPadding
                    ),
                    entries: entries
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(document)
                try data.write(to: destinationURL, options: .atomic)
                let availableCount = entries.filter(\.isAvailable).count
                let capturedCount = entries.count {
                    $0.snapshot != nil
                }
                let duration = Date().timeIntervalSince(captureStartedAt)
                state.reportOutput = "Exported \(capturedCount)/\(availableCount) available "
                    + "Semantic Usage × Main trees (\(entries.count) entries) in "
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

    func exportPassAudit() {
        guard state.rendererMode == .recipe else {
            state.reportOutput = "Switch Renderer to Recipe before exporting a Pass Audit."
            return
        }
        guard state.windowHostType == .panel else {
            state.reportOutput = "Switch Host Type to Panel before exporting the canonical Pass Audit."
            return
        }
        guard !state.hasActiveOverrides else {
            state.reportOutput = "Disable Override before exporting a clean system Pass Audit."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "recursive-pass-audit.json"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        liveRefreshTask?.cancel()
        isCapturingPassAudit = true
        passAuditCaptureTask = Task { @MainActor in
            let originalVisibility = state.isTestWindowVisible
            let originalMainState = state.isTestWindowMain
            let originalSubdued = state.isSubdued
            let originalScrim = state.hasScrim
            let originalReducedTintOpacity = state.hasReducedTintOpacity
            let originalAdaptiveAppearance = state.adaptiveAppearance
            let originalTint = state.tintColor
            let originalGlassWidth = state.glassWidth
            let originalGlassHeight = state.glassHeight
            let originalCornerRadius = state.cornerRadius
            let originalWindowPadding = state.windowPadding
            let captureStartedAt = Date()
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .userInitiated,
                    .idleSystemSleepDisabled,
                    .idleDisplaySleepDisabled,
                ],
                reason: "Capturing the Glass Lab Recursive Pass Audit"
            )

            defer {
                ProcessInfo.processInfo.endActivity(activity)
                state.windowPadding = originalWindowPadding
                restoreTestWindowContext(
                    visibility: originalVisibility,
                    isMainWindow: originalMainState,
                    isSubdued: originalSubdued,
                    hasScrim: originalScrim,
                    hasReducedTintOpacity: originalReducedTintOpacity,
                    adaptiveAppearance: originalAdaptiveAppearance,
                    tintColor: originalTint,
                    glassWidth: originalGlassWidth,
                    glassHeight: originalGlassHeight,
                    cornerRadius: originalCornerRadius
                )
                passAuditCaptureTask = nil
            }

            if !state.isTestWindowVisible {
                state.isTestWindowVisible = true
                state.testWindow.sync(with: state)
            }
            state.isCapturingRecipeMatrix = true
            state.hasScrim = false
            state.hasReducedTintOpacity = false
            state.adaptiveAppearance = 2
            state.tintColor = nil
            state.glassWidth = 480
            state.glassHeight = 200
            state.cornerRadius = 16
            state.windowPadding = 40

            var entries: [GlassLabTuning.PassAuditEntry] = []
            let totalContexts = 4
            var completedContexts = 0

            do {
                for wantsMain in [false, true] {
                    for subdued in [false, true] {
                        var participationRetries = 0
                        contextRetry: while true {
                            try await waitUntilApplicationIsActive(
                                progress: "Pass context \(completedContexts + 1)/\(totalContexts), "
                                    + "\(entries.count)/336 entries"
                            )
                            state.glassWidth = 480
                            state.glassHeight = 200
                            state.cornerRadius = 16
                            state.windowPadding = 40
                            state.isTestWindowMain = wantsMain
                            state.isSubdued = subdued
                            state.testWindow.sync(with: state)
                            if let glass = state.testWindow.liveGlass {
                                GlassLabTuning.applyRecipe(from: state, to: glass)
                            }
                            try await Task.sleep(for: .milliseconds(300))
                            guard NSApp.isActive else { continue contextRetry }
                            guard state.testWindow.isActuallyMain == wantsMain,
                                  !state.testWindow.isActuallyKey,
                                  let glass = state.testWindow.liveGlass else {
                                participationRetries += 1
                                guard participationRetries < 4 else {
                                    throw MatrixExportError.participationRejected(
                                        main: wantsMain,
                                        subdued: subdued,
                                        height: 200
                                    )
                                }
                                continue contextRetry
                            }

                            let context = "panel"
                                + (wantsMain ? "-main" : "-neither")
                                + (subdued ? "-subdued" : "-standard")
                            do {
                                let batch = try await GlassLabTuning.capturePassAudit(
                                    on: glass,
                                    context: context,
                                    requestedMain: wantsMain,
                                    subdued: subdued,
                                    restoring: state
                                )
                                entries += batch
                                completedContexts += 1
                                state.reportOutput = "Captured Pass context "
                                    + "\(completedContexts)/\(totalContexts), "
                                    + "\(entries.count)/336 entries."
                                break contextRetry
                            } catch GlassLabTuning.MatrixCaptureError.applicationInactive {
                                continue contextRetry
                            } catch GlassLabTuning.MatrixCaptureError.participationChanged {
                                participationRetries += 1
                                guard participationRetries < 4 else {
                                    throw MatrixExportError.participationRejected(
                                        main: wantsMain,
                                        subdued: subdued,
                                        height: 200
                                    )
                                }
                                continue contextRetry
                            } catch GlassLabTuning.MatrixCaptureError.missingLayerTree {
                                throw MatrixExportError.invalidMatrix(
                                    "Recursive Pass Audit could not capture a stable layer tree."
                                )
                            }
                        }
                    }
                }

                if let validationFailure = validatePassAudit(entries) {
                    throw MatrixExportError.invalidMatrix(validationFailure)
                }

                let document = GlassLabTuning.PassAuditDocument(
                    formatVersion: 1,
                    capturedAt: ISO8601DateFormatter().string(from: Date()),
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    axes: .init(
                        main: [false, true],
                        subdued: [false, true],
                        variants: GlassLabTuning.variants,
                        subvariants: [nil]
                            + GlassLabTuning.knownSubvariants.map(Optional.some)
                    ),
                    context: .init(
                        hostType: GlassLabWindowHostType.panel.rawValue,
                        windowMargin: 40,
                        glassWidth: 480,
                        glassHeight: 200,
                        cornerRadius: 16,
                        scrim: false,
                        reducedTintOpacity: false,
                        adaptiveAppearance: 2,
                        tint: nil,
                        overridesEnabled: false
                    ),
                    entries: entries
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(document)
                try data.write(to: destinationURL, options: .atomic)
                let topologyCount = Set(entries.map(\.snapshot.topologySignature)).count
                let valueCount = Set(entries.map(\.snapshot.valueSignature)).count
                let duration = Date().timeIntervalSince(captureStartedAt)
                state.reportOutput = "Exported \(entries.count) recursive Pass entries "
                    + "(\(topologyCount) topology / \(valueCount) value signatures) in "
                    + "\(String(format: "%.1f", duration)) seconds to "
                    + destinationURL.path
            } catch is CancellationError {
                state.reportOutput = "Recursive Pass Audit cancelled; no file was written."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                state.reportOutput = "Recursive Pass Audit failed; no file was written.\n"
                    + message
            }
        }
    }

    func exportMatrix() {
        guard !state.hasActiveOverrides else {
            state.reportOutput = "Disable Override before exporting a clean system Recipe Matrix."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "recipe-matrix.json"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isCapturingMatrix = true
        matrixCaptureTask = Task { @MainActor in
            let originalVisibility = state.isTestWindowVisible
            let originalMainState = state.isTestWindowMain
            let originalSubdued = state.isSubdued
            let originalScrim = state.hasScrim
            let originalReducedTintOpacity = state.hasReducedTintOpacity
            let originalAdaptiveAppearance = state.adaptiveAppearance
            let originalTint = state.tintColor
            let originalGlassWidth = state.glassWidth
            let originalGlassHeight = state.glassHeight
            let originalCornerRadius = state.cornerRadius
            let captureStartedAt = Date()
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .userInitiated,
                    .idleSystemSleepDisabled,
                    .idleDisplaySleepDisabled,
                ],
                reason: "Capturing the Glass Lab Golden Standard"
            )

            defer {
                ProcessInfo.processInfo.endActivity(activity)
                restoreTestWindowContext(
                    visibility: originalVisibility,
                    isMainWindow: originalMainState,
                    isSubdued: originalSubdued,
                    hasScrim: originalScrim,
                    hasReducedTintOpacity: originalReducedTintOpacity,
                    adaptiveAppearance: originalAdaptiveAppearance,
                    tintColor: originalTint,
                    glassWidth: originalGlassWidth,
                    glassHeight: originalGlassHeight,
                    cornerRadius: originalCornerRadius
                )
                matrixCaptureTask = nil
            }

            if !state.isTestWindowVisible {
                state.isTestWindowVisible = true
                state.testWindow.sync(with: state)
            }
            state.isCapturingRecipeMatrix = true
            state.hasScrim = false
            state.hasReducedTintOpacity = false
            state.adaptiveAppearance = 2
            state.tintColor = nil

            let sizeSamples = [24, 200, 600].map {
                GlassLabTuning.MatrixDocument.Axes.SizeSample(
                    width: 480,
                    height: Double($0),
                    cornerRadius: 16
                )
            }
            let environment = GlassLabTuning.MatrixDocument.Environment(
                hostType: state.windowHostType.rawValue,
                windowMargin: state.windowPadding,
                scrim: false,
                reducedTintOpacity: false,
                adaptiveAppearance: 2,
                tint: nil,
                overridesEnabled: false
            )

            var entries: [GlassLabTuning.MatrixEntry] = []
            let totalContexts = sizeSamples.count * 2 * 2
            var completedContexts = 0

            do {
                for size in sizeSamples {
                    for wantsMain in [false, true] {
                        for subdued in [false, true] {
                            var participationRetries = 0
                            contextRetry: while true {
                                try await waitUntilApplicationIsActive(
                                    progress: "Context \(completedContexts + 1)/\(totalContexts), "
                                        + "\(entries.count)/1,008 entries"
                                )
                                state.glassWidth = size.width
                                state.glassHeight = size.height
                                state.cornerRadius = size.cornerRadius
                                state.isTestWindowMain = wantsMain
                                state.isSubdued = subdued
                                state.testWindow.sync(with: state)
                                if let glass = state.testWindow.liveGlass {
                                    // Host updates intentionally skip Recipe
                                    // writes during capture; stamp this context
                                    // before walking the private axes.
                                    GlassLabTuning.applyRecipe(from: state, to: glass)
                                }
                                try await Task.sleep(for: .milliseconds(300))
                                guard NSApp.isActive else { continue contextRetry }
                                guard state.testWindow.isActuallyMain == wantsMain,
                                      !state.testWindow.isActuallyKey,
                                      let glass = state.testWindow.liveGlass else {
                                    participationRetries += 1
                                    guard participationRetries < 4 else {
                                        throw MatrixExportError.participationRejected(
                                            main: wantsMain,
                                            subdued: subdued,
                                            height: size.height
                                        )
                                    }
                                    continue contextRetry
                                }

                                let context = state.windowHostType.contextID
                                    + (wantsMain ? "-main" : "-neither")
                                    + (subdued ? "-subdued" : "-standard")
                                do {
                                    let batch = try await GlassLabTuning.captureMatrix(
                                        on: glass,
                                        context: context,
                                        requestedMain: wantsMain,
                                        subdued: subdued,
                                        restoring: state
                                    )
                                    entries += batch
                                    completedContexts += 1
                                    state.reportOutput = "Captured context "
                                        + "\(completedContexts)/\(totalContexts), "
                                        + "\(entries.count)/1,008 entries."
                                    break contextRetry
                                } catch GlassLabTuning.MatrixCaptureError.applicationInactive {
                                    // Do not retain a partial 84-cell batch.
                                    // Wait for activation, restore Main, and
                                    // repeat this context from its first cell.
                                    continue contextRetry
                                } catch GlassLabTuning.MatrixCaptureError.participationChanged {
                                    participationRetries += 1
                                    guard participationRetries < 4 else {
                                        throw MatrixExportError.participationRejected(
                                            main: wantsMain,
                                            subdued: subdued,
                                            height: size.height
                                        )
                                    }
                                    continue contextRetry
                                }
                            }
                        }
                    }
                }

                if let validationFailure = validateMatrix(
                    entries,
                    sizeSamples: sizeSamples
                ) {
                    throw MatrixExportError.invalidMatrix(validationFailure)
                }

                let document = GlassLabTuning.MatrixDocument(
                    schemaVersion: 1,
                    capturedAt: ISO8601DateFormatter().string(from: Date()),
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    axes: .init(
                        main: [false, true],
                        subdued: [false, true],
                        variants: GlassLabTuning.variants,
                        subvariants: [nil] + GlassLabTuning.knownSubvariants.map(Optional.some),
                        sizes: sizeSamples
                    ),
                    environment: environment,
                    entries: entries
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(document)
                try data.write(to: destinationURL, options: .atomic)
                let duration = Date().timeIntervalSince(captureStartedAt)
                state.reportOutput = "Exported \(entries.count) complete recipe entries "
                    + "in \(String(format: "%.1f", duration)) seconds to "
                    + destinationURL.path
            } catch is CancellationError {
                state.reportOutput = "Recipe Matrix capture cancelled; no file was written."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                state.reportOutput = "Recipe Matrix capture failed; no file was written.\n"
                    + message
            }
        }
    }

    @MainActor
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

    func validateMatrix(
        _ entries: [GlassLabTuning.MatrixEntry],
        sizeSamples: [GlassLabTuning.MatrixDocument.Axes.SizeSample]
    ) -> String? {
        let subvariants: [String?] = [nil]
            + GlassLabTuning.knownSubvariants.map(Optional.some)
        var expectedIdentities: Set<String> = []
        for size in sizeSamples {
            for main in [false, true] {
                for subdued in [false, true] {
                    for variant in GlassLabTuning.variants {
                        for subvariant in subvariants {
                            expectedIdentities.insert(matrixIdentity(
                                width: size.width,
                                height: size.height,
                                cornerRadius: size.cornerRadius,
                                main: main,
                                subdued: subdued,
                                variant: variant,
                                subvariant: subvariant
                            ))
                        }
                    }
                }
            }
        }

        let actualIdentities = Set(entries.map {
            matrixIdentity(
                width: $0.glassWidth,
                height: $0.glassHeight,
                cornerRadius: $0.cornerRadius,
                main: $0.requestedMain,
                subdued: $0.subdued,
                variant: $0.variant,
                subvariant: $0.subvariant
            )
        })
        guard entries.count == expectedIdentities.count,
              actualIdentities == expectedIdentities else {
            return "Expected \(expectedIdentities.count) unique Cartesian-product rows, "
                + "captured \(entries.count) rows / \(actualIdentities.count) identities."
        }
        guard entries.allSatisfy(\.appActive) else {
            return "At least one row was captured while the application was inactive."
        }
        guard entries.allSatisfy({
            !$0.isActualKeyWindow && $0.isActualMainWindow == $0.requestedMain
        }) else {
            return "At least one row does not match its requested Main participation."
        }
        return nil
    }

    func validatePassAudit(
        _ entries: [GlassLabTuning.PassAuditEntry]
    ) -> String? {
        let subvariants: [String?] = [nil]
            + GlassLabTuning.knownSubvariants.map(Optional.some)
        var expectedIdentities: Set<String> = []
        for main in [false, true] {
            for subdued in [false, true] {
                for variant in GlassLabTuning.variants {
                    for subvariant in subvariants {
                        expectedIdentities.insert(matrixIdentity(
                            width: 480,
                            height: 200,
                            cornerRadius: 16,
                            main: main,
                            subdued: subdued,
                            variant: variant,
                            subvariant: subvariant
                        ))
                    }
                }
            }
        }

        let actualIdentities = Set(entries.map {
            matrixIdentity(
                width: $0.glassWidth,
                height: $0.glassHeight,
                cornerRadius: $0.cornerRadius,
                main: $0.requestedMain,
                subdued: $0.subdued,
                variant: $0.variant,
                subvariant: $0.subvariant
            )
        })
        guard entries.count == 336,
              actualIdentities.count == 336,
              actualIdentities == expectedIdentities else {
            return "Recursive Pass Audit requires 336 unique fixed-geometry Cartesian-product rows."
        }
        guard entries.allSatisfy({
            $0.appActive
                && !$0.isActualKeyWindow
                && $0.isActualMainWindow == $0.requestedMain
        }) else {
            return "Recursive Pass Audit contains an inactive or rejected window context."
        }
        guard entries.allSatisfy({
            !$0.snapshot.layers.isEmpty
                && !$0.snapshot.topologySignature.isEmpty
                && !$0.snapshot.valueSignature.isEmpty
        }) else {
            return "Recursive Pass Audit contains an empty or unsigned layer tree."
        }
        return nil
    }

    func matrixIdentity(
        width: Double,
        height: Double,
        cornerRadius: Double,
        main: Bool,
        subdued: Bool,
        variant: Int,
        subvariant: String?
    ) -> String {
        "\(width)x\(height)@\(cornerRadius)"
            + "|main=\(main)|subdued=\(subdued)|variant=\(variant)"
            + "|subvariant=\(subvariant ?? "<nil>")"
    }

    @MainActor
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
        isCapturingPassAudit = false
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
#endif
