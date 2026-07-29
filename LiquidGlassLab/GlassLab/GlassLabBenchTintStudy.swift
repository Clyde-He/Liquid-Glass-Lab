//
//  GlassLabBenchTintStudy.swift
//  LiquidGlassLab
//
//  Bench: the full Tint Study driver — the fixed-context capture that
//  produced the 28/20/40-row tint archive, its UI page, and its export.
//  Research tooling only; no tweaking behavior lives here.
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension GlassLabView {
    enum TintStudyError: LocalizedError {
        case contextRejected(String)
        case missingAppKitSnapshot
        case missingSemanticSnapshot
        case transitionContextChanged
        case invalidCounts(appKit: Int, semantic: Int, transitions: Int)
        case invalidMaterializeStudy(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case let .contextRejected(context):
                "Tint study could not establish \(context)."
            case .missingAppKitSnapshot:
                "Tint study could not capture the NSGlass pass tree."
            case .missingSemanticSnapshot:
                "Tint study could not capture the SwiftUI semantic tree."
            case .transitionContextChanged:
                "Tint study lost its requested Main/Key context during Materialize."
            case let .invalidCounts(appKit, semantic, transitions):
                "Tint study expected 28/20/40 rows but captured "
                    + "\(appKit)/\(semantic)/\(transitions)."
            case let .invalidMaterializeStudy(expected, actual):
                "P1 Materialize study expected \(expected) transitions but "
                    + "captured \(actual)."
            }
        }
    }

    @ViewBuilder
    func tintStudySections(
        state labState: GlassLabState
    ) -> some View {
        @Bindable var state = labState

        Section("Full Tint Study") {
            Text("Captures one controlled document spanning static NSGlass routing, static SwiftUI endpoints, and explicit-linear SwiftUI Materialize insertion/removal. Every row records the fixed window contract, complete model/presentation pass trees, and layer color state.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent("NSGlass Static") {
                Text("28 rows")
                    .monospacedDigit()
            }
            LabeledContent("SwiftUI Static") {
                Text("20 rows")
                    .monospacedDigit()
            }
            LabeledContent("SwiftUI Transition") {
                Text("40 runs · 360 samples")
                    .monospacedDigit()
            }
            LabeledContent("Tint Cases") {
                Text("nil · Coral 25/50/100% · Cyan 50% · Reduced controls")
                    .multilineTextAlignment(.trailing)
            }

            Button("Capture Full Tint Study") {
                captureFullTintStudy()
            }
            .disabled(isCapturingTintStudy)

            if isCapturingTintStudy {
                ProgressView(tintStudyStatus ?? "Capturing Tint study…")
                    .controlSize(.small)
            } else if let tintStudyStatus {
                Text(tintStudyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let tintStudyDocument {
            Section("Latest Study") {
                LabeledContent("AppKit Static") {
                    Text(String(tintStudyDocument.appKitStatic.count))
                        .monospacedDigit()
                }
                LabeledContent("SwiftUI Static") {
                    Text(String(tintStudyDocument.swiftUIStatic.count))
                        .monospacedDigit()
                }
                LabeledContent("Transitions") {
                    Text(String(tintStudyDocument.swiftUITransitions.count))
                        .monospacedDigit()
                }
                HStack {
                    Button("Copy Study Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            tintStudyDocument.report,
                            forType: .string
                        )
                    }
                    Button("Export Study JSON") {
                        exportTintStudy()
                    }
                }
                Text(tintStudyDocument.report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }

        Section("Current Tint Preview") {
            ColorPicker(
                "Tint Color",
                selection: tintBinding,
                supportsOpacity: true
            )
            Toggle(
                "Reduced Tint Opacity (NSGlass only)",
                isOn: $state.hasReducedTintOpacity
            )
            .disabled(
                !(state.testWindow.liveGlass.map {
                    GlassLabTuning.supportsReducedTintOpacitySetter(on: $0)
                } ?? false)
            )
            Text("Tint remains available for qualitative follow-up. Reduced Tint Opacity is a capability probe: it is disabled when the runtime exposes no guarded setter. The automated study records that availability instead of treating a skipped write as an effect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func captureFullTintStudy() {
        guard !isCapturingTintStudy else { return }
        guard !state.hasActiveOverrides else {
            tintStudyStatus =
                "Disable Filter, Rim, and Color Matrix overrides before capturing."
            return
        }

        cancelMaterializeCapture()
        liveRefreshTask?.cancel()
        tintStudyDocument = nil
        tintStudyStatus = "Preparing fixed Tint study context…"
        isCapturingTintStudy = true

        let originalRenderer = state.rendererMode
        let originalRecipePage = selectedRecipePage
        let originalSemanticPage = selectedSemanticPage
        let originalUsage = state.semanticUsage
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
        let originalPadding = state.windowPadding
        let originalVisibility = state.isTestWindowVisible
        let originalMaterializeMain = materializeRequestedMain
        let originalMaterializeAppearance = materializeRequestedAppearance
        let originalMaterializeBackdrop = materializeRequestedBackdrop
        let originalMaterializeMode = materializeAnimationMode
        let originalMaterializeDuration = materializeLinearDuration
        let originalMaterializePresented = materializePresented

        tintStudyTask = Task { @MainActor in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .userInitiated,
                    .idleSystemSleepDisabled,
                    .idleDisplaySleepDisabled,
                ],
                reason: "Capturing Full Liquid Glass Tint Study"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                state.rendererMode = originalRenderer
                selectedRecipePage = originalRecipePage
                selectedSemanticPage = originalSemanticPage
                state.semanticUsage = originalUsage
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
                state.windowPadding = originalPadding
                state.isTestWindowVisible = originalVisibility
                materializeRequestedMain = originalMaterializeMain
                materializeRequestedAppearance =
                    originalMaterializeAppearance
                materializeRequestedBackdrop = originalMaterializeBackdrop
                materializeAnimationMode = originalMaterializeMode
                materializeLinearDuration = originalMaterializeDuration
                materializePresented = originalMaterializePresented
                state.testWindow.sync(with: state)
                configureSemanticTransitionProbe()
                isCapturingTintStudy = false
                tintStudyTask = nil
                scheduleLiveReadoutRefresh(refreshSchema: true)
            }

            do {
                configureFixedTintStudyContext()
                var appKitEntries: [GlassLabAppKitTintEntry] = []
                var semanticEntries: [GlassLabSemanticTintEntry] = []
                var transitionEntries: [GlassLabMaterializeCapture] = []

                state.rendererMode = .recipe
                selectedRecipePage = .tint
                state.testWindow.sync(with: state)
                try await Task.sleep(for: .milliseconds(240))

                let appKitTotal = 2 * 2 * GlassLabTintPreset.allCases.count
                var appKitIndex = 0
                for requestedMain in [false, true] {
                    for variant in [1, 2] {
                        for tintPreset in GlassLabTintPreset.allCases {
                            appKitIndex += 1
                            tintStudyStatus =
                                "NSGlass static \(appKitIndex)/\(appKitTotal) · "
                                + "V\(variant) · Main "
                                + (requestedMain ? "On" : "Off")
                                + " · \(tintPreset.displayName)"
                            appKitEntries.append(
                                try await captureAppKitTintEntry(
                                    variant: variant,
                                    requestedMain: requestedMain,
                                    tintPreset: tintPreset
                                )
                            )
                        }
                    }
                }

                state.rendererMode = .semanticUsage
                selectedSemanticPage = .general
                state.hasReducedTintOpacity = false
                state.testWindow.sync(with: state)
                configureSemanticTransitionProbe()
                try await Task.sleep(for: .milliseconds(240))

                let semanticTotal =
                    2 * 2 * GlassLabTintPreset.semanticCases.count
                var semanticIndex = 0
                for requestedMain in [false, true] {
                    for usage in [
                        GlassLabSemanticUsage.regular,
                        GlassLabSemanticUsage.clear,
                    ] {
                        for tintPreset in GlassLabTintPreset.semanticCases {
                            semanticIndex += 1
                            tintStudyStatus =
                                "SwiftUI static \(semanticIndex)/\(semanticTotal) · "
                                + "\(usage.displayName) · Main "
                                + (requestedMain ? "On" : "Off")
                                + " · \(tintPreset.displayName)"
                            semanticEntries.append(
                                try await captureSemanticTintEntry(
                                    usage: usage,
                                    requestedMain: requestedMain,
                                    tintPreset: tintPreset
                                )
                            )
                        }
                    }
                }

                selectedSemanticPage = .transition
                materializeAnimationMode = .linear
                materializeLinearDuration = 1
                configureSemanticTransitionProbe()
                let transitionTotal = 2
                    * 2
                    * GlassLabTintPreset.transitionCases.count
                    * GlassLabMaterializeDirection.allCases.count
                var transitionIndex = 0
                for requestedMain in [false, true] {
                    for usage in [
                        GlassLabSemanticUsage.regular,
                        GlassLabSemanticUsage.clear,
                    ] {
                        for tintPreset in GlassLabTintPreset.transitionCases {
                            for direction in GlassLabMaterializeDirection.allCases {
                                transitionIndex += 1
                                tintStudyStatus =
                                    "SwiftUI Transition "
                                    + "\(transitionIndex)/\(transitionTotal) · "
                                    + "\(usage.displayName) · Main "
                                    + (requestedMain ? "On" : "Off")
                                    + " · \(tintPreset.displayName)"
                                    + " · \(direction.rawValue)"
                                transitionEntries.append(
                                    try await performMaterializeCapture(
                                        usage: usage,
                                        direction: direction,
                                        animationMode: .linear,
                                        linearDuration: 1,
                                        requestedMain: requestedMain,
                                        tint: tintPreset.descriptor,
                                        tintColor: tintPreset.color,
                                        appearance: .system,
                                        backdrop: .ambient
                                    )
                                )
                            }
                        }
                    }
                }

                guard appKitEntries.count == 28,
                      semanticEntries.count == 20,
                      transitionEntries.count == 40 else {
                    throw TintStudyError.invalidCounts(
                        appKit: appKitEntries.count,
                        semantic: semanticEntries.count,
                        transitions: transitionEntries.count
                    )
                }
                guard transitionEntries.allSatisfy({
                    $0.samples.count == 9
                        && $0.context.actualMain == $0.context.requestedMain
                        && !$0.context.actualKey
                }) else {
                    throw TintStudyError.transitionContextChanged
                }

                let document = GlassLabTintStudyDocument(
                    formatVersion: 1,
                    capturedAt: ISO8601DateFormatter().string(from: Date()),
                    operatingSystem:
                        ProcessInfo.processInfo.operatingSystemVersionString,
                    context: .init(
                        hostType: GlassLabWindowHostType.panel.rawValue,
                        glassWidth: 480,
                        glassHeight: 200,
                        cornerRadius: 16,
                        windowMargin: 40,
                        adaptiveAppearance: 2,
                        subvariant: nil,
                        subdued: false,
                        scrim: false,
                        overridesEnabled: false,
                        transitionAnimation:
                            GlassLabMaterializeAnimationMode.linear.rawValue,
                        transitionDuration: 1
                    ),
                    appKitStatic: appKitEntries,
                    swiftUIStatic: semanticEntries,
                    swiftUITransitions: transitionEntries
                )
                tintStudyDocument = document
                state.reportOutput = document.report
                tintStudyStatus =
                    "Complete · 28 AppKit rows · 20 SwiftUI rows · "
                    + "40 transitions / 360 samples."
            } catch is CancellationError {
                tintStudyStatus = "Tint study cancelled; partial data discarded."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                tintStudyStatus = "Tint study failed: \(message)"
                state.reportOutput = tintStudyStatus ?? message
            }
        }
    }

    @MainActor
    func configureFixedTintStudyContext() {
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
        state.windowHostType = .panel
        state.testAppearance = .system
        state.testBackdrop = .ambient
        state.isTestWindowMain = false
        state.windowPadding = 40
        state.isTestWindowVisible = true
        materializePresented = true
        state.testWindow.sync(with: state)
    }

    @MainActor
    func captureAppKitTintEntry(
        variant: Int,
        requestedMain: Bool,
        tintPreset: GlassLabTintPreset
    ) async throws -> GlassLabAppKitTintEntry {
        state.variant = variant
        state.isTestWindowMain = requestedMain
        state.tintColor = tintPreset.color
        state.hasReducedTintOpacity = tintPreset.reducedTintOpacity

        for attempt in 1...5 {
            try await waitUntilApplicationIsActive(
                progress: tintStudyStatus ?? "NSGlass Tint study paused."
            )
            state.testWindow.sync(with: state)
            guard let glass = state.testWindow.liveGlass else {
                try await Task.sleep(for: .milliseconds(180))
                continue
            }
            GlassLabTuning.applyRecipe(from: state, to: glass)
            do {
                let model = try await GlassLabTuning
                    .settledPassAuditSnapshot(from: glass)
                guard NSApp.isActive,
                      state.testWindow.isActuallyMain == requestedMain,
                      !state.testWindow.isActuallyKey else {
                    if attempt < 5 { continue }
                    throw TintStudyError.contextRejected(
                        "NSGlass V\(variant) · Main "
                            + (requestedMain ? "On" : "Off")
                    )
                }
                CATransaction.flush()
                let presentationRoot = glass.layer?.presentation()
                return GlassLabAppKitTintEntry(
                    variant: variant,
                    material: variant == 1 ? "Regular" : "Clear",
                    requestedMain: requestedMain,
                    actualMain: state.testWindow.isActuallyMain,
                    actualKey: state.testWindow.isActuallyKey,
                    tint: tintPreset.descriptor,
                    storedTint: GlassLabTintDescriptor(
                        label: "NSGlass readback",
                        color: glass.tintColor,
                        reducedTintOpacity:
                            capturedReducedTintOpacity(from: glass) ?? false
                    ),
                    reducedTintOpacitySetterAvailable:
                        reducedTintOpacitySetterAvailable(on: glass),
                    reducedTintOpacityGetterAvailable:
                        reducedTintOpacityGetterAvailable(on: glass),
                    storedReducedTintOpacity:
                        capturedReducedTintOpacity(from: glass),
                    snapshot: GlassLabAppKitTintSnapshot(
                        model: model,
                        presentation:
                            GlassLabTuning.capturePassAuditSnapshot(
                                from: presentationRoot
                            ),
                        modelLayerAppearance:
                            GlassLabTuning.captureTintLayerAppearance(
                                from: glass.layer
                            ),
                        presentationLayerAppearance:
                            presentationRoot.map {
                                GlassLabTuning.captureTintLayerAppearance(
                                    from: $0
                                )
                            }
                    )
                )
            } catch GlassLabTuning.MatrixCaptureError.applicationInactive {
                continue
            } catch GlassLabTuning.MatrixCaptureError.missingLayerTree {
                if attempt == 5 {
                    throw TintStudyError.missingAppKitSnapshot
                }
            }
        }
        throw TintStudyError.contextRejected(
            "NSGlass V\(variant) · Main "
                + (requestedMain ? "On" : "Off")
        )
    }

    @MainActor
    func capturedReducedTintOpacity(
        from glass: NSGlassEffectView
    ) -> Bool? {
        let object = glass as NSObject
        let key = "_tintOpacityReduced"
        guard reducedTintOpacityGetterAvailable(on: glass) else {
            return nil
        }
        return (object.value(forKey: key) as? NSNumber)?.boolValue
    }

    @MainActor
    func reducedTintOpacityGetterAvailable(
        on glass: NSGlassEffectView
    ) -> Bool {
        (glass as NSObject).responds(
            to: NSSelectorFromString("_tintOpacityReduced")
        )
    }

    @MainActor
    func reducedTintOpacitySetterAvailable(
        on glass: NSGlassEffectView
    ) -> Bool {
        GlassLabTuning.supportsReducedTintOpacitySetter(on: glass)
    }

    @MainActor
    func captureSemanticTintEntry(
        usage: GlassLabSemanticUsage,
        requestedMain: Bool,
        tintPreset: GlassLabTintPreset
    ) async throws -> GlassLabSemanticTintEntry {
        state.semanticUsage = usage
        state.isTestWindowMain = requestedMain
        state.tintColor = tintPreset.color
        materializePresented = true
        state.testWindow.sync(with: state)
        configureSemanticTransitionProbe()

        for attempt in 1...5 {
            try await waitUntilApplicationIsActive(
                progress: tintStudyStatus ?? "SwiftUI Tint study paused."
            )
            state.testWindow.sync(with: state)
            configureSemanticTransitionProbe()
            try await Task.sleep(for: .milliseconds(240))
            try Task.checkCancellation()
            guard NSApp.isActive,
                  state.testWindow.isActuallyMain == requestedMain,
                  !state.testWindow.isActuallyKey else {
                if attempt < 5 { continue }
                throw TintStudyError.contextRejected(
                    "SwiftUI \(usage.displayName) · Main "
                        + (requestedMain ? "On" : "Off")
                )
            }
            if let snapshot = captureCurrentMaterializeSnapshot() {
                return GlassLabSemanticTintEntry(
                    roleTag: usage.rawValue,
                    usage: usage.displayName,
                    requestedMain: requestedMain,
                    actualMain: state.testWindow.isActuallyMain,
                    actualKey: state.testWindow.isActuallyKey,
                    tint: tintPreset.descriptor,
                    snapshot: snapshot
                )
            }
        }
        throw TintStudyError.missingSemanticSnapshot
    }

    func exportTintStudy() {
        guard let document = tintStudyDocument else {
            tintStudyStatus = "Capture the full Tint study before exporting."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "glass-tint-study.json"
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: destinationURL, options: .atomic)
            let rowCount = document.appKitStatic.count
                + document.swiftUIStatic.count
                + document.swiftUITransitions.count
            tintStudyStatus = "Exported \(rowCount) study rows to "
                + destinationURL.path
            state.reportOutput = tintStudyStatus ?? document.report
        } catch {
            tintStudyStatus = "Tint study export failed: \(error.localizedDescription)"
        }
    }

    /// Built with named intermediates rather than inline in the row: as one
    /// concatenation inside the section body it timed out the type checker.
    static func previewContextSummary(state: GlassLabState) -> String {
        let requestedMain = state.isTestWindowMain ? "On" : "Off"
        let actualMain = state.testWindow.isActuallyMain ? "On" : "Off"
        let effectiveAppearance = state.testWindow.effectiveAppearanceName ?? "?"
        return "\(state.windowHostType.rawValue)"
            + " · requested Main \(requestedMain)"
            + " · actual \(actualMain)"
            + " · \(state.testAppearance.rawValue) / \(effectiveAppearance)"
            + " · \(state.testBackdrop.rawValue) backdrop"
    }
}
#endif
