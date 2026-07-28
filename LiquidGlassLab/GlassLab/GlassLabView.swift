//
//  GlassLabView.swift
//  LiquidGlassLab
//
//  Interactive laboratory for the macOS 26 Liquid Glass private rendering
//  stack. The control window owns no preview glass; one independent AppKit
//  test window can be rebuilt across host types and real participation states.
//  See Documentation/GlassLabPlayground.md for the lab's state, refresh,
//  Inspector, Override, and export contracts.
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct GlassLabView: View {
    private enum RecipePage: String, CaseIterable, Identifiable {
        case general = "General"
        case passes = "Passes"
        case materialize = "Materialize"
        case tint = "Tint"

        var id: Self { self }
    }

    private enum SemanticPage: String, CaseIterable, Identifiable {
        case general = "General"
        case layerInspector = "Layer Inspector"
        case transition = "Transition"

        var id: Self { self }
    }

    private enum MatrixExportError: LocalizedError {
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

    private enum SemanticExportError: LocalizedError {
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

    private enum TintStudyError: LocalizedError {
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

    let state: GlassLabState
    @State private var selectedRecipePage = RecipePage.general
    @State private var selectedPassSlotID: String?
    @State private var selectedSemanticPage = SemanticPage.general
    @State private var isCapturingMatrix = false
    @State private var isCapturingPassAudit = false
    @State private var isCapturingSemanticTrees = false
    @State private var liveSnapshot: LiveReadoutSnapshot?
    @State private var passInventorySnapshot: GlassLabTuning.PassAuditSnapshot?
    @State private var passObjectIdentityBySlot: [String: ObjectIdentifier] = [:]
    @State private var replacedPassSlots: Set<String> = []
    @State private var semanticSnapshot: GlassLabSemanticSnapshot?
    @State private var materializeAnimationMode:
        GlassLabMaterializeAnimationMode = .systemDefault
    @State private var materializeLinearDuration = 4.0
    @State private var materializeRequestedMain = false
    @State private var materializeRequestedAppearance:
        GlassLabTestAppearance = .system
    @State private var materializeRequestedBackdrop:
        GlassLabBackdropMode = .ambient
    /// The geometry the probe is currently waiting to settle into. Fixed at the
    /// baseline 480×200 for every page and study except the geometry sweep.
    @State private var materializeRequestedSize = CGSize(
        width: 480,
        height: 200
    )
    @State private var materializePresented = true
    @State private var materializeCapture: GlassLabMaterializeCapture?
    @State private var materializeCaptureStatus: String?
    @State private var materializeCaptureTask: Task<Void, Never>?
    @State private var isCapturingMaterialize = false
    @State private var materializeStudyDocument:
        GlassLabMaterializeStudyDocument?
    @State private var materializeStudyStatus: String?
    @State private var materializeStudyTask: Task<Void, Never>?
    @State private var isCapturingMaterializeStudy = false
    @State private var appKitMaterializeVariant = 1
    @State private var appKitMaterializeRequestedMain = false
    @State private var appKitMaterializeProgress = 1.0
    @State private var appKitMaterializeIncludesViewEnvelope = false
    @State private var appKitMaterializeResult:
        GlassLabTuning.MaterializeBackgroundTransplantResult?
    @State private var appKitMaterializeStatus: String?
    @State private var appKitMaterializeTask: Task<Void, Never>?
    @State private var isAnimatingAppKitMaterialize = false
    @State private var tintStudyDocument: GlassLabTintStudyDocument?
    @State private var tintStudyStatus: String?
    @State private var tintStudyTask: Task<Void, Never>?
    @State private var isCapturingTintStudy = false
    @State private var shaderOverrideBaseline: LiveReadoutSnapshot?
    @State private var highlightOverrideBaseline: LiveReadoutSnapshot?
    @State private var vibrantMatrixOverrideBaseline:
        [String: GlassLabTuning.VibrantColorMatrixOverridePayload]?
    @State private var inspectorShaderGroups: [GlassLabTuning.ShaderKnobGroup] = []
    @State private var inspectorShaderMetadata: [String: GlassLabTuning.AttributeMetadata] = [:]
    @State private var inspectorHighlightMetadata: [String: GlassLabTuning.AttributeMetadata] = [:]
    @State private var liveRefreshTask: Task<Void, Never>?
    @State private var matrixCaptureTask: Task<Void, Never>?
    @State private var passAuditCaptureTask: Task<Void, Never>?
    @State private var semanticCaptureTask: Task<Void, Never>?
    @State private var foregroundProbeTask: Task<Void, Never>?
    @State private var foregroundProbeReport: ForegroundProbeReport?
    @State private var foregroundProbeStatus: String?
    @State private var isForegroundProbeRunning = false
    @State private var vibrantMatrixProbeTask: Task<Void, Never>?
    @State private var vibrantMatrixProbeReports: [VibrantMatrixCaseReport] = []
    @State private var vibrantMatrixProbeStatus: String?
    @State private var isVibrantMatrixProbeRunning = false
    @State private var hasPendingSchemaRefresh = false

    var body: some View {
        labForm
        .background(GlassLabControlWindowAnchor(state: state).frame(width: 0, height: 0))
        .navigationTitle(state.rendererMode.navigationTitle)
        .onAppear {
            state.testWindow.activate(with: state)
            configureSemanticTransitionProbe()
            scheduleLiveReadoutRefresh(refreshSchema: true)
        }
        .task {
            await runHeadlessCaptureIfRequested()
        }
        .onChange(of: liveReadoutTrigger) {
            state.testWindow.sync(with: state)
            scheduleLiveReadoutRefresh()
        }
        .onChange(of: overridePayloadTrigger) {
            restampOverridesIfNeeded()
            scheduleLiveReadoutRefresh()
        }
        .onChange(of: recipeStructureTrigger) {
            cancelForegroundProbe(clearReport: true)
            if !isCapturingMaterialize {
                cancelMaterializeCapture()
            }
            if state.rendererMode != .recipe {
                cancelAppKitMaterializeProbe(rebuild: false)
            } else if selectedRecipePage == .materialize,
                      !isAnimatingAppKitMaterialize,
                      !appKitMaterializeProbeContextIsReady {
                requestAppKitMaterializeProbeContext()
            }
            state.testWindow.sync(with: state)
            configureSemanticTransitionProbe()
            scheduleLiveReadoutRefresh(refreshSchema: true)
        }
        .onChange(of: selectedRecipePage) {
            if selectedRecipePage == .materialize {
                requestAppKitMaterializeProbeContext()
            } else {
                cancelAppKitMaterializeProbe(rebuild: true)
            }
            scheduleLiveReadoutRefresh()
        }
        .onChange(of: appKitMaterializeVariant) {
            if state.rendererMode == .recipe,
               selectedRecipePage == .materialize {
                requestAppKitMaterializeProbeContext()
            } else {
                cancelAppKitMaterializeProbe(rebuild: true)
            }
        }
        .onChange(of: appKitMaterializeRequestedMain) {
            if state.rendererMode == .recipe,
               selectedRecipePage == .materialize {
                requestAppKitMaterializeProbeContext()
            } else {
                cancelAppKitMaterializeProbe(rebuild: true)
            }
        }
        .onChange(of: selectedSemanticPage) {
            cancelMaterializeCapture()
            state.testWindow.sync(with: state)
            configureSemanticTransitionProbe()
            scheduleLiveReadoutRefresh()
        }
        .onReceive(liveContextNotifications) { notification in
            if notification.name == NSApplication.didBecomeActiveNotification {
                state.testWindow.applicationDidBecomeActive(with: state)
                if state.rendererMode == .recipe,
                   selectedRecipePage == .materialize,
                   !appKitMaterializeProbeContextIsReady,
                   !isAnimatingAppKitMaterialize {
                    requestAppKitMaterializeProbeContext()
                }
            } else if notification.name == NSApplication.didResignActiveNotification {
                state.testWindow.applicationDidResignActive(with: state)
            }
            if let window = notification.object as? NSWindow {
                guard window === state.testWindow.liveWindow else { return }
            }
            scheduleLiveReadoutRefresh()
        }
        .onDisappear {
            liveRefreshTask?.cancel()
            matrixCaptureTask?.cancel()
            passAuditCaptureTask?.cancel()
            semanticCaptureTask?.cancel()
            foregroundProbeTask?.cancel()
            vibrantMatrixProbeTask?.cancel()
            materializeCaptureTask?.cancel()
            materializeStudyTask?.cancel()
            appKitMaterializeTask?.cancel()
            tintStudyTask?.cancel()
        }
    }

    private var labForm: some View {
        labFormContent(snapshot: liveSnapshot)
    }

    private func labFormContent(snapshot: LiveReadoutSnapshot?) -> some View {
        @Bindable var state = state
        return VStack(spacing: 0) {
            Group {
                switch state.rendererMode {
                case .recipe:
                    Picker("Recipe Page", selection: $selectedRecipePage) {
                        ForEach(RecipePage.allCases) { page in
                            Text(page.rawValue).tag(page)
                        }
                    }
                case .semanticUsage:
                    Picker("Semantic Page", selection: $selectedSemanticPage) {
                        ForEach(SemanticPage.allCases) { page in
                            Text(page.rawValue).tag(page)
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(isCapturingTintStudy)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider()

            if state.rendererMode == .recipe, selectedRecipePage == .passes {
                // Passes renders outside the Form: the grouped section platter
                // cannot be suppressed per-row on macOS, and it double-boxes
                // the control-group cards. Plain stacked boxes keep grouping
                // to a single visual layer.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        passNavigatorSections(
                            state: state,
                            liveSnapshot: snapshot,
                            passSnapshot: passInventorySnapshot
                        )
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(
                    isCapturingMatrix
                        || isCapturingPassAudit
                        || isCapturingSemanticTrees
                        || isCapturingTintStudy
                )
            } else {
            Form {
                switch state.rendererMode {
                case .recipe:
                switch selectedRecipePage {
                case .general:
            Section("Geometry") {
                labeledSlider("Width", value: $state.glassWidth, in: 60...900)
                labeledSlider("Height", value: $state.glassHeight, in: 24...600)
                labeledSlider("Corner Radius", value: $state.cornerRadius, in: 0...80)
                Text("Recipes resolve against the glass's shortest side — several inputs use min(width, height) (blur band = -shortSide/2, shadow height = 0.4×shortSide) and cap out on larger surfaces. Corner Radius changes the SDF/path geometry but not the numeric recipe inputs. The independent test window always renders the requested glass at its true size.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Glass Material (Private API)") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Variant", selection: $state.variant) {
                        ForEach(GlassLabTuning.variants, id: \.self) { variant in
                            Text(GlassLabTuning.variantLabel(for: variant)).tag(variant)
                        }
                    }
                    Text("The material recipe behind the public style property: Regular writes 1, Clear writes 2, a fresh view starts at 0. Other values are private recipes used across the system. On this runtime, 13 and 14 intentionally produce no glassBackground pass.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Subvariant", text: $state.subvariant, prompt: Text("none"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        ForEach(GlassLabTuning.knownSubvariants, id: \.self) { name in
                            Button(name) { state.subvariant = name }
                        }
                        Button("clear") { state.subvariant = "" }
                    }
                    Text("Independent, case-sensitive recipe axis. A popped-up menu is Variant 0 + \"menu\". The property stores arbitrary strings, but only menu/sheet/camera changed output in our probes. The resolver consumes names for some Variants and ignores them for others; it is not a global override.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $state.isSubdued) {
                    LabRowLabel(
                        "Subdued",
                        description: "Independent lower-emphasis axis. In tested recipes it suppresses active Shader/Rim even while Main is On; layer geometry can still retain Main-dependent values."
                    )
                }
                Toggle(isOn: $state.hasScrim) {
                    LabRowLabel(
                        "Scrim",
                        description: "Inserts the system's legibility scrim — a dimming wash between the backdrop and the glass face."
                    )
                }
                Toggle(isOn: $state.hasReducedTintOpacity) {
                    LabRowLabel(
                        "Reduced Tint Opacity",
                        description: "Private capability probe. This runtime exposes neither the guarded setter nor a getter, so the control is unavailable and does not claim a material effect."
                    )
                }
                .disabled(
                    !(state.testWindow.liveGlass.map {
                        GlassLabTuning.supportsReducedTintOpacitySetter(on: $0)
                    } ?? false)
                )

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Adaptive Appearance", selection: $state.adaptiveAppearance) {
                        Text("0").tag(0)
                        Text("1").tag(1)
                        Text("2 — Default (adaptive)").tag(2)
                    }
                    Text("Private NSGlass raw field. Values 0/1/2 are writable, but current evidence does not map them to macOS Light/Dark or prove that they pin backdrop adaptation. Use Test Window Appearance and Backdrop below for controlled public-environment experiments.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ColorPicker("Tint Color", selection: tintBinding, supportsOpacity: true)
                    Text("Public tintColor. System chrome like the Music mini player is a clear-family variant plus a deep, mostly-opaque tint — the variants alone never produce that look. Zero opacity removes the tint.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button("Reset Glass Material") { state.resetRecipe() }
            }

            generalWindowSections(state: state)

                case .passes:
                    EmptyView()
                case .materialize:
                    appKitMaterializeSections(state: state)
                case .tint:
                    tintStudySections(state: state)
                }

                case .semanticUsage:
                switch selectedSemanticPage {
                case .general:
                    semanticGeneralSections(state: state)
                case .layerInspector:
                    semanticInspectorSections(state: state, snapshot: semanticSnapshot)
                case .transition:
                    semanticTransitionSections(state: state)
                }

                }
        }
        .formStyle(.grouped)
        .disabled(
            isCapturingMatrix
                || isCapturingPassAudit
                || isCapturingSemanticTrees
                || isCapturingTintStudy
        )
            }
        }
    }

    @ViewBuilder
    private func glassFilterEditorSections(
        state labState: GlassLabState,
        snapshot: LiveReadoutSnapshot?
    ) -> some View {
        ForEach(GlassLabTuning.ShaderGroup.allCases) { group in
            controlGroupCard(group.sectionTitle) {
                shaderGroupControls(
                    group,
                    knobs: inspectorShaderGroups.first { $0.group == group }?.knobs ?? [],
                    state: labState,
                    snapshot: snapshot
                )
            }
        }

        controlGroupCard("Owner Layer · Render Margin") {
            geometryControls(
                state: labState,
                snapshot: snapshot,
                keys: ["backdropMarginWidth"]
            )
        }
    }

    @ViewBuilder
    private func rimHighlightEditorSections(
        state labState: GlassLabState,
        snapshot: LiveReadoutSnapshot?
    ) -> some View {
        ForEach(GlassLabTuning.HighlightGroup.allCases) { group in
            controlGroupCard(
                group.sectionTitle.replacingOccurrences(of: "Rim Highlight · ", with: "")
            ) {
                highlightGroupControls(group, state: labState, snapshot: snapshot)
            }
        }
    }

    @ViewBuilder
    private func outputEffectEditorSections(
        state labState: GlassLabState,
        snapshot: LiveReadoutSnapshot?
    ) -> some View {
        controlGroupCard("Render Bounds") {
            geometryControls(
                state: labState,
                snapshot: snapshot,
                keys: ["sdfOutputMinimum", "sdfOutputMaximum"]
            )
        }
    }

    @ViewBuilder
    private func foregroundAberrationProbeSections(
        item: PassInventoryItem
    ) -> some View {
        controlGroupCard("Variant 14 · Aberration Mutation Probe") {
            Text("Each probe rebuilds a fresh Recipe tree, changes only inputAberrationAmount, then compares model and presentation readback after Core Animation settles. This is an audit tool, not an accepted material control.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Prepare Baseline") { prepareForegroundProbeBaseline() }
                Button("Fresh → nil") {
                    runForegroundAberrationProbe(value: nil, item: item)
                }
                .disabled(!foregroundProbeContextIsReady || isForegroundProbeRunning)
                Button("Fresh → 0") {
                    runForegroundAberrationProbe(value: 0, item: item)
                }
                .disabled(!foregroundProbeContextIsReady || isForegroundProbeRunning)
                Button("Fresh → 1") {
                    runForegroundAberrationProbe(value: 1, item: item)
                }
                .disabled(!foregroundProbeContextIsReady || isForegroundProbeRunning)
                Button("Rebuild / Reset") { resetForegroundAberrationProbe() }
                    .disabled(isForegroundProbeRunning)
            }

            if !foregroundProbeContextIsReady {
                Text("Prepare the accepted fixed context: Panel, Main Off, 480×200@16, Margin 40, Variant 14, no Subvariant/Subdued/Override.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if isForegroundProbeRunning {
                ProgressView("Rebuilding, mutating, and sampling the settling window…")
                    .controlSize(.small)
            }
            if let foregroundProbeStatus {
                Text(foregroundProbeStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let report = foregroundProbeReport {
                Divider()
                LabeledContent("Requested") {
                    Text(report.requestedValue).monospacedDigit()
                }
                LabeledContent("Model") {
                    Text(
                        "\(probeValue(report.before, presentation: false)) → "
                            + "\(probeValue(report.immediate, presentation: false)) → "
                            + "\(probeValue(report.settled, presentation: false))"
                    )
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                }
                LabeledContent("Presentation") {
                    Text(
                        "\(probeValue(report.before, presentation: true)) → "
                            + "\(probeValue(report.immediate, presentation: true)) → "
                            + "\(probeValue(report.settled, presentation: true))"
                    )
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                }
                LabeledContent("Pass Object") {
                    Text(report.objectWasReplaced ? "Replaced" : "Retained")
                        .foregroundStyle(report.objectWasReplaced ? .orange : .secondary)
                }
                LabeledContent("Owner Gate") {
                    Text(
                        "opacity \(formatKnobValue(report.settled.layerOpacity))"
                            + (report.settled.layerIsHidden ? " · hidden" : " · visible")
                    )
                    .font(.system(.callout, design: .monospaced))
                }
                LabeledContent("Source") {
                    Text(report.settled.sourceSublayerName ?? "nil")
                        .font(.system(.callout, design: .monospaced))
                }
                LabeledContent("Animations") {
                    Text(
                        report.settled.animationKeyPaths.isEmpty
                            ? "none"
                            : report.settled.animationKeyPaths.joined(separator: ", ")
                    )
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                }
                Button("Copy Probe Report") {
                    let text = foregroundProbeReportText(report)
                    state.reportOutput = text
                    copyToPasteboard(text)
                }
            }
        }
    }

    @ViewBuilder
    private func vibrantColorMatrixProbeSections() -> some View {
        controlGroupCard("Regular / Clear · Matrix Pass Validation") {
            Text("Runs both same-named vibrantColorMatrix slots through Variant 1/2 × Main Off/On. Every case writes all three Boolean inputs, nudges one matrix coefficient, checks model/presentation and the peer slot, then rebuilds to prove Recipe reset.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Run Full 8-Case Suite") {
                    runVibrantColorMatrixProbeSuite()
                }
                .disabled(isVibrantMatrixProbeRunning)
                if isVibrantMatrixProbeRunning {
                    Button("Cancel") {
                        vibrantMatrixProbeTask?.cancel()
                    }
                }
                if !vibrantMatrixProbeReports.isEmpty {
                    Button("Copy Matrix Probe Report") {
                        let text = vibrantMatrixProbeReportText(
                            vibrantMatrixProbeReports
                        )
                        state.reportOutput = text
                        copyToPasteboard(text)
                    }
                }
            }

            if isVibrantMatrixProbeRunning {
                ProgressView(vibrantMatrixProbeStatus ?? "Preparing the controlled suite…")
                    .controlSize(.small)
            } else if let vibrantMatrixProbeStatus {
                Text(vibrantMatrixProbeStatus)
                    .font(.caption)
                    .foregroundStyle(
                        vibrantMatrixProbeReports.allSatisfy(\.accepted)
                            ? AnyShapeStyle(.green)
                            : AnyShapeStyle(.orange)
                    )
            }

            if !vibrantMatrixProbeReports.isEmpty {
                Divider()
                ForEach(vibrantMatrixProbeReports) { report in
                    LabeledContent(
                        "V\(report.variant) · Main \(report.requestedMain ? "On" : "Off") · Slot \(report.ordinal)"
                    ) {
                        Text(report.accepted ? "PASS" : "FAIL")
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(report.accepted ? .green : .red)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func vibrantColorMatrixEditorSections(
        item: PassInventoryItem,
        state labState: GlassLabState
    ) -> some View {
        let payload = labState.vibrantMatrixOverrides[item.slotID]
        let isEditable = labState.vibrantMatrixOverridesEnabled && payload != nil
        let livePayload = selectedReadoutGlass.flatMap {
            GlassLabTuning.captureVibrantColorMatrixOverride(
                from: $0,
                matching: item.record
            )
        }
        let displayedPayload = payload ?? livePayload
        let liveObservation = selectedReadoutGlass.flatMap {
            GlassLabTuning.captureVibrantColorMatrixProbe(
                from: $0,
                matching: item.record
            )
        }

        controlGroupCard("Pass Inputs · Slot \(item.ordinal)/\(item.familyCount)") {
            Text("Override Off shows the live system values read-only. Enable it to capture both matrices and edit this structural slot; nil/Off/On remains explicit for every Boolean input.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let liveObservation {
                LabeledContent("Live Model / Presentation · m00") {
                    Text(
                        "\(formatMatrixCoefficient(liveObservation.modelMatrixFirstCoefficient)) / "
                            + (liveObservation.presentationMatrixFirstCoefficient.map(
                                formatMatrixCoefficient
                            ) ?? "unavailable")
                    )
                    .font(.system(.callout, design: .monospaced))
                }
            }

            if let displayedPayload {
                ForEach(
                    [
                        "inputBackdropAware",
                        "inputClamp",
                        "inputClampPreserveHue",
                    ],
                    id: \.self
                ) { key in
                    LabeledContent(key) {
                        Picker(
                            key,
                            selection: vibrantMatrixBooleanBinding(
                                slotID: item.slotID,
                                key: key,
                                liveValue: displayedPayload.booleanValues[key]
                                    ?? .nilValue
                            )
                        ) {
                            ForEach(
                                GlassLabTuning.VibrantBooleanOverrideValue.allCases
                            ) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!isEditable)
                    }
                }
            } else {
                Text("Live pass inputs unavailable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        controlGroupCard("Color Matrix · 4×5 Float") {
            Text("Rows are output R/G/B/A; columns are input R/G/B/A plus Bias. Each edit atomically re-boxes the full validated 80-byte NSValue.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let displayedPayload,
               displayedPayload.matrixCoefficients.count == 20 {
                Grid(
                    alignment: .trailing,
                    horizontalSpacing: 6,
                    verticalSpacing: 6
                ) {
                    GridRow {
                        Text("")
                        ForEach(["R", "G", "B", "A", "Bias"], id: \.self) {
                            Text($0)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(0..<4, id: \.self) { row in
                        GridRow {
                            Text(["R", "G", "B", "A"][row])
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(0..<5, id: \.self) { column in
                                let index = row * 5 + column
                                TextField(
                                    "m\(row)\(column)",
                                    value: vibrantMatrixCoefficientBinding(
                                        slotID: item.slotID,
                                        index: index,
                                        liveValue: displayedPayload
                                            .matrixCoefficients[index]
                                    ),
                                    format: .number.precision(
                                        .fractionLength(0...6)
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 68)
                                .disabled(!isEditable)
                            }
                        }
                    }
                }
            } else {
                Text("Live color matrix unavailable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatMatrixCoefficient(_ value: Float) -> String {
        String(format: "%.6g", value)
    }

    /// A semantic knob group as its own single-layer card: the group name is
    /// the card's header, the card is the only grouping container.
    private func controlGroupCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func semanticGeneralSections(state labState: GlassLabState) -> some View {
        @Bindable var state = labState

        Section("Geometry") {
            labeledSlider("Width", value: $state.glassWidth, in: 60...900)
            labeledSlider("Height", value: $state.glassHeight, in: 24...600)
            labeledSlider("Corner Radius", value: $state.cornerRadius, in: 0...80)
            Text("SwiftUI owns this semantic surface and resolves its complete SDF/layer composition at the requested size. Size and Corner Radius are shared with Recipe mode only as lab geometry; they do not turn a Usage into an NSGlass raw Variant.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        Section("Semantic Usage (Private SwiftUI)") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Usage", selection: $state.semanticUsage) {
                    ForEach(GlassLabSemanticUsage.allCases) { usage in
                        let available = GlassLabSemanticRuntime.shared.isAvailable(usage)
                        Text(
                            "\(usage.rawValue) · \(usage.displayName)"
                                + (available ? "" : " — Unavailable")
                        )
                        .tag(usage)
                        .disabled(!available)
                    }
                }
                Text("The number is SwiftUI `_Glass.Variant.Role`'s runtime tag. It is not NSGlassEffectView `_variant`, and it is not the same ordinal table exported by DesignLibrary/electron-liquid-glass.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Runtime Role Tag") {
                Text(String(state.semanticUsage.rawValue))
                    .monospacedDigit()
            }
            LabeledContent("Runtime Availability") {
                Text(GlassLabSemanticRuntime.shared.status(for: state.semanticUsage))
                    .foregroundStyle(
                        GlassLabSemanticRuntime.shared.isAvailable(state.semanticUsage)
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.red)
                    )
            }

            Text(state.semanticUsage.implementationHint)
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        Section("Public Tint") {
            ColorPicker(
                "Glass Tint",
                selection: tintBinding,
                supportsOpacity: true
            )
            Text("Applies SwiftUI `Glass.tint(_:)` to the resolved Regular, Clear, or private semantic Usage. Zero opacity restores nil so static and Transition captures share one explicit tint axis.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        generalWindowSections(state: state)
    }

    @ViewBuilder
    private func passNavigatorSections(
        state labState: GlassLabState,
        liveSnapshot: LiveReadoutSnapshot?,
        passSnapshot: GlassLabTuning.PassAuditSnapshot?
    ) -> some View {
        let items = passSnapshot.map(passInventoryItems) ?? []
        let selectedItem = selectedPassItem(in: items)

        labBox {
            if passSnapshot == nil {
                Text("No Recipe layer tree is available yet.")
                    .foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text("The current layer tree contains no inspectable pass objects.")
                    .foregroundStyle(.secondary)
            } else if let selectedItem {
                HStack(spacing: 12) {
                    Text("Pass")
                    Spacer()
                    Text(passState(for: selectedItem, state: labState))
                        .foregroundStyle(.secondary)
                    Picker("Pass Instance", selection: $selectedPassSlotID) {
                        ForEach(items) { item in
                            Text(passInventorySectionTitle(item))
                                .tag(Optional(item.slotID))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .help(passIdentityHelp(for: selectedItem))

                Divider()

                overrideRow(state: labState, snapshot: liveSnapshot)

                if !passFamilyHasControls(selectedItem.family) {
                    Divider()
                    Text("Read-only until this exact pass family and property type have an accepted live-mutation and reset contract.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let selectedItem, passFamilyHasControls(selectedItem.family) {
            labSectionHeader("Controls")

            switch selectedItem.family {
            case "glassBackground":
                glassFilterEditorSections(state: labState, snapshot: liveSnapshot)
            case "CASDFKeyFillHighlightEffect":
                rimHighlightEditorSections(state: labState, snapshot: liveSnapshot)
            case "CASDFOutputEffect":
                outputEffectEditorSections(state: labState, snapshot: liveSnapshot)
            case "glassForeground":
                foregroundAberrationProbeSections(item: selectedItem)
            case "vibrantColorMatrix":
                vibrantColorMatrixEditorSections(
                    item: selectedItem,
                    state: labState
                )
                vibrantColorMatrixProbeSections()
            default:
                EmptyView()
            }
        }

        if let passSnapshot {
            labSectionHeader("Audit")
            labBox {
                if let selectedItem {
                    DisclosureGroup("Properties (\(selectedItem.record.properties.count))") {
                        VStack(alignment: .leading, spacing: 8) {
                            selectedPassPropertyRows(selectedItem)
                        }
                        .padding(.top, 6)
                    }
                    Divider()
                }
                DisclosureGroup("Diagnostics") {
                    VStack(alignment: .leading, spacing: 8) {
                        passDiagnosticsRows(items: items, snapshot: passSnapshot)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    /// Single-layer grouping container for the Form-free Passes page.
    private func labBox<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func labSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 10)
    }

    /// The Pass row's hover help carries the selected pass's identity so the
    /// header stays at two rows.
    private func passIdentityHelp(for item: PassInventoryItem) -> String {
        [
            "Object \(item.record.objectClass)",
            "Owner \(item.record.layerClass)",
            "Location \(item.record.location)",
            "Locator \(item.record.layerPath)",
            "Contract \(passMutationContractSummary(for: item))",
        ].joined(separator: "\n")
    }

    private func passFamilyHasControls(_ family: String) -> Bool {
        family == "glassBackground"
            || family == "CASDFKeyFillHighlightEffect"
            || family == "CASDFOutputEffect"
            || family == "glassForeground"
            || family == "vibrantColorMatrix"
    }

    /// One global Override switch for the whole page. Enabling captures every
    /// present override channel (the Glass Filter payload, which includes
    /// Output/geometry values, both Matrix slots, and the Rim pass when it
    /// exists); disabling discards all baselines and rebuilds the system glass.
    private func overrideRow(
        state labState: GlassLabState,
        snapshot: LiveReadoutSnapshot?
    ) -> some View {
        let isEnabled = labState.hasActiveOverrides
        let canEnable = snapshot?.shaderInputKeys != nil
            || snapshot?.highlightInputKeys != nil
            || passInventorySnapshot?.passes.values.contains {
                $0.name == "vibrantColorMatrix"
            } == true
        return HStack(spacing: 12) {
            Text("Override")
            Spacer()
            Button("Reset") { resetAllOverrides() }
                .disabled(!isEnabled)
            Toggle("Override", isOn: overridesEnabledBinding)
                .labelsHidden()
                .disabled(!canEnable && !isEnabled)
        }
    }

    /// Identity rows followed by the complete declared-property list. Every
    /// property is a row so accepted and read-only contracts can be compared
    /// without a per-property selection step.
    @ViewBuilder
    private func selectedPassPropertyRows(_ item: PassInventoryItem) -> some View {
        LabeledContent("Object Class") {
            Text(item.record.objectClass)
                .font(.system(.body, design: .monospaced))
        }
        LabeledContent("Owner") {
            Text(item.record.layerClass)
                .font(.system(.body, design: .monospaced))
        }
        LabeledContent("Location") {
            Text(item.record.location)
                .font(.system(.body, design: .monospaced))
        }
        LabeledContent("Structural Locator") {
            Text(item.record.layerPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        LabeledContent("Contract") {
            Text(passMutationContractSummary(for: item))
                .foregroundStyle(.secondary)
        }

        let propertyKeys = item.record.properties.keys.sorted()
        if propertyKeys.isEmpty {
            Text("This pass declares no inspectable properties.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(propertyKeys, id: \.self) { key in
                if let property = item.record.properties[key] {
                    let classification = GlassLabTuning.classifyPassProperty(
                        property,
                        key: key,
                        in: item.record
                    )
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(property.value ?? property.state)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text(classification.contract)
                                .font(.caption2)
                                .foregroundStyle(
                                    classification.isMutationAccepted
                                        ? AnyShapeStyle(.green)
                                        : AnyShapeStyle(.secondary)
                                )
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key)
                            Text("\(property.state.capitalized) · \(classification.presentation.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help(
                        property.attributes.isEmpty
                            ? key
                            : key + "\n" + passPropertyMetadata(property.attributes)
                    )
                }
            }
        }
    }

    /// Whole-snapshot audit data: capture context, counts, signatures, the
    /// deterministic report, and the raw recursive layer tree. None of it
    /// depends on the selected pass.
    @ViewBuilder
    private func passDiagnosticsRows(
        items: [PassInventoryItem],
        snapshot: GlassLabTuning.PassAuditSnapshot
    ) -> some View {
        let acceptedPropertyCount = items.reduce(into: 0) { count, item in
            count += item.record.properties.filter { key, property in
                GlassLabTuning.classifyPassProperty(
                    property,
                    key: key,
                    in: item.record
                ).isMutationAccepted
            }.count
        }

        Text(readoutDescription)
            .font(.callout)
            .foregroundStyle(.secondary)

        LabeledContent("Layers") {
            Text(String(snapshot.layers.count)).monospacedDigit()
        }
        LabeledContent("Passes") {
            Text(String(snapshot.passes.count)).monospacedDigit()
        }
        LabeledContent("Replaced") {
            Text(String(items.filter {
                replacedPassSlots.contains($0.slotID)
            }.count))
            .monospacedDigit()
        }
        LabeledContent("Accepted Contracts") {
            Text(String(acceptedPropertyCount)).monospacedDigit()
        }
        LabeledContent("Topology") {
            Text(String(snapshot.topologySignature.prefix(12)))
                .font(.system(.body, design: .monospaced))
                .help(snapshot.topologySignature)
        }
        LabeledContent("Values") {
            Text(String(snapshot.valueSignature.prefix(12)))
                .font(.system(.body, design: .monospaced))
                .help(snapshot.valueSignature)
        }

        Button("Copy Pass Inventory Report") { copyPassInventoryReport() }

        ScrollView(.horizontal) {
            Text(passLayerReport(snapshot))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func semanticInspectorSections(
        state labState: GlassLabState,
        snapshot: GlassLabSemanticSnapshot?
    ) -> some View {
        @Bindable var state = labState

        Section("Semantic Layer Inspector") {
            Picker("Usage", selection: $state.semanticUsage) {
                ForEach(GlassLabSemanticUsage.allCases) { usage in
                    let available = GlassLabSemanticRuntime.shared.isAvailable(usage)
                    Text(
                        "\(usage.rawValue) · \(usage.displayName)"
                            + (available ? "" : " — Unavailable")
                    )
                    .tag(usage)
                    .disabled(!available)
                }
            }
            Text(semanticReadoutDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("This is the live SwiftUI/Core Animation composition, not an NSGlassEffectView Inspector. Values are read-only until each Usage-specific input has a measured mutation contract and safe range.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let snapshot {
                LabeledContent("Layers") {
                    Text(String(snapshot.layerLines.count)).monospacedDigit()
                }
                LabeledContent("Filters") {
                    Text(String(snapshot.filters.count)).monospacedDigit()
                }
                LabeledContent("Effects") {
                    Text(String(snapshot.effects.count)).monospacedDigit()
                }
            }

            HStack {
                Button("Copy Semantic Report") { copySemanticReport() }
                    .disabled(snapshot == nil)
                Button(
                    isCapturingSemanticTrees
                        ? "Capturing…"
                        : "Export All Usage Trees (JSON)"
                ) {
                    exportSemanticUsageTrees()
                }
                .disabled(isCapturingSemanticTrees)
            }
        }

        Section("Layer Tree") {
            if let snapshot {
                ScrollView(.horizontal) {
                    Text(snapshot.layerLines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No semantic layer tree is available yet.")
                    .foregroundStyle(.secondary)
            }
        }

        if let snapshot {
            if snapshot.filters.isEmpty {
                Section("Filters") {
                    Text("No CAFilter pass is present for this Usage.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(snapshot.filters) { filter in
                    Section("Filter · \(filter.name)") {
                        LabeledContent("Layer") {
                            Text(filter.layerClass).foregroundStyle(.secondary)
                        }
                        LabeledContent("Path") {
                            Text(filter.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        ForEach(filter.inputs) { input in
                            LabeledContent(input.key) {
                                Text(input.value)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            if snapshot.effects.isEmpty {
                Section("SDF Effects") {
                    Text("No object-backed SDF effect is present for this Usage.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(snapshot.effects) { effect in
                    Section("Effect · \(effect.effectClass)") {
                        LabeledContent("Layer") {
                            Text(effect.layerClass).foregroundStyle(.secondary)
                        }
                        LabeledContent("Opacity") {
                            Text(formatKnobValue(effect.layerOpacity))
                                .monospacedDigit()
                        }
                        LabeledContent("Path") {
                            Text(effect.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        ForEach(effect.inputs) { input in
                            LabeledContent(input.key) {
                                Text(input.value)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func appKitMaterializeSections(
        state labState: GlassLabState
    ) -> some View {
        @Bindable var state = labState
        let materializeBackgroundFieldCount =
            appKitMaterializeRequestedMain
                ? (appKitMaterializeVariant == 1 ? 38 : 33)
                : (appKitMaterializeVariant == 1 ? 22 : 23)

        Section("SwiftUI → NSGlass Transplant") {
            Picker("Public Endpoint", selection: $appKitMaterializeVariant) {
                Text("Regular").tag(1)
                Text("Clear").tag(2)
            }
            .disabled(isAnimatingAppKitMaterialize)

            Picker(
                "Participation",
                selection: $appKitMaterializeRequestedMain
            ) {
                Text("Main Off").tag(false)
                Text("Main On").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(isAnimatingAppKitMaterialize)

            ColorPicker(
                "Tint Endpoint",
                selection: appKitMaterializeTintBinding,
                supportsOpacity: true
            )
            .disabled(isAnimatingAppKitMaterialize)
            HStack {
                Button("Coral 50%") {
                    setAppKitMaterializeTint(
                        NSColor(
                            srgbRed: 0.92,
                            green: 0.18,
                            blue: 0.38,
                            alpha: 0.5
                        )
                    )
                }
                Button("Clear Tint") {
                    setAppKitMaterializeTint(nil)
                }
            }
            .disabled(isAnimatingAppKitMaterialize)

            Text("This probe replays only channels whose pass already exists in the matching NSGlass tree. Main Off uses the measured 22/23-field background vector. Main On uses its distinct 38/33-field vector and the observed discrete Rim gate. A nonnil public Tint adds its own matrix branch; only coefficient 18 receives sourceAlpha × g². SwiftUI-only passes are never injected.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent("glassBackground") {
                Text(
                    "\(materializeBackgroundFieldCount)"
                        + " changing fields · direct transplant"
                )
                    .foregroundStyle(.green)
            }
            LabeledContent("View Envelope") {
                Text("opacity + nonuniform scale · optional comparison")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Content gaussianBlur") {
                Text("pass absent in stable NSGlass")
                    .foregroundStyle(.orange)
            }
            LabeledContent("glassForeground") {
                Text("pass absent in Regular / Clear NSGlass")
                    .foregroundStyle(.orange)
            }
            LabeledContent("Content/Rim Matrix · Output") {
                Text("observed stable · intentionally untouched")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Tint Matrix") {
                Text(
                    state.tintColor == nil
                        ? "nil · branch absent"
                        : "coefficient 18 · sourceAlpha × g²"
                )
                .foregroundStyle(
                    state.tintColor == nil
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.green)
                )
            }
            LabeledContent("Rim") {
                Text(
                    appKitMaterializeRequestedMain
                        ? "owner gate · 0 at g=0, 1 while active"
                        : "system Main-Off gate · untouched"
                )
                .foregroundStyle(
                    appKitMaterializeRequestedMain ? .green : .secondary
                )
            }
        }

        Section("Probe Context") {
            LabeledContent("Variant") {
                Text(GlassLabTuning.variantLabel(for: state.variant))
            }
            LabeledContent("Host / Participation") {
                Text(
                    "\(state.windowHostType.rawValue) · requested Main "
                        + "\(state.isTestWindowMain ? "On" : "Off")"
                        + " · actual \(state.testWindow.isActuallyMain ? "On" : "Off")"
                )
            }
            LabeledContent("Geometry") {
                Text(
                    "\(formatKnobValue(state.glassWidth))×"
                        + "\(formatKnobValue(state.glassHeight))"
                        + "@\(formatKnobValue(state.cornerRadius))"
                        + " · margin \(formatKnobValue(state.windowPadding))"
                )
                .monospacedDigit()
            }

            Text("Entering this page automatically prepares Panel, 480×200@16, Margin 40, the selected Regular/Clear endpoint, and the selected Main participation. Controls unlock only after actual Main/Key state matches.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appKitMaterializeProbeContextIsReady {
                Text("Context ready.")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text(
                    "Synchronizing Panel, requested and actual Main "
                        + (appKitMaterializeRequestedMain ? "On" : "Off")
                        + ", actual Key Off, and the fixed probe baseline…"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        Section("Shared-Pass Progress") {
            labeledSlider(
                "Materialize g",
                value: appKitMaterializeProgressBinding,
                in: 0...1
            )
            .disabled(!appKitMaterializeProbeContextIsReady
                || isAnimatingAppKitMaterialize)

            Toggle(
                isOn: appKitMaterializeViewEnvelopeBinding
            ) {
                LabRowLabel(
                    "Include View Envelope",
                    description: "Comparison-only: also applies the observed whole-content opacity and nonuniform scale. Keep this Off to judge the reusable glassBackground pass by itself."
                )
            }
            .disabled(!appKitMaterializeProbeContextIsReady
                || isAnimatingAppKitMaterialize)

            HStack {
                Button("Linear In · 4s") {
                    animateAppKitMaterialize(to: 1)
                }
                Button("Linear Out · 4s") {
                    animateAppKitMaterialize(to: 0)
                }
                Button("Restore Endpoint") {
                    setAppKitMaterializeProgress(1)
                }
            }
            .disabled(!appKitMaterializeProbeContextIsReady
                || isAnimatingAppKitMaterialize)

            if isAnimatingAppKitMaterialize {
                ProgressView(appKitMaterializeStatus ?? "Replaying transplant…")
                    .controlSize(.small)
            } else if let appKitMaterializeStatus {
                Text(appKitMaterializeStatus)
                    .font(.caption)
                    .foregroundStyle(
                        appKitMaterializeResult?.isAccepted == false
                            ? AnyShapeStyle(.orange)
                            : AnyShapeStyle(.secondary)
                    )
            }
        }

        if let result = appKitMaterializeResult {
            Section("Latest Readback") {
                LabeledContent("Endpoint") {
                    Text(result.variant == 1 ? "Regular" : "Clear")
                }
                LabeledContent("Participation") {
                    Text(result.requestedMain ? "Main On" : "Main Off")
                }
                LabeledContent("Progress") {
                    Text(formatKnobValue(result.progress)).monospacedDigit()
                }
                LabeledContent("Background Keys") {
                    Text(
                        "\(result.acceptedKeyCount)/\(result.requestedKeys.count)"
                    )
                    .monospacedDigit()
                    .foregroundStyle(result.missingKeys.isEmpty ? .green : .orange)
                }
                LabeledContent("Model Readback") {
                    Text(
                        result.mismatchedKeys.isEmpty
                            ? "all requested values matched"
                            : "\(result.mismatchedKeys.count) mismatches"
                    )
                    .foregroundStyle(
                        result.mismatchedKeys.isEmpty ? .green : .orange
                    )
                }
                if result.requestedMain {
                    LabeledContent("Rim Gate") {
                        Text(
                            "\(result.acceptedRimKeyCount)/"
                                + "\(result.requestedRimKeys.count)"
                        )
                        .monospacedDigit()
                        .foregroundStyle(
                            result.missingRimKeys.isEmpty
                                && result.mismatchedRimKeys.isEmpty
                                ? .green : .orange
                        )
                    }
                }
                if let requestedAlpha = result.requestedTintAlpha,
                   let expectedAlpha = result.expectedTintMatrixAlpha {
                    LabeledContent("Tint Matrix α") {
                        Text(
                            "source \(formatKnobValue(requestedAlpha)) · "
                                + "expected \(formatKnobValue(expectedAlpha)) · "
                                + "read \(result.actualTintMatrixAlpha.map(formatKnobValue) ?? "missing")"
                        )
                        .monospacedDigit()
                        .foregroundStyle(
                            result.tintMatrixFound && result.tintMatrixMatched
                                ? .green : .orange
                        )
                    }
                }
                if !result.missingKeys.isEmpty {
                    LabeledContent("Missing") {
                        Text(result.missingKeys.joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if !result.mismatchedKeys.isEmpty {
                    LabeledContent("Mismatch") {
                        Text(result.mismatchedKeys.joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if !result.missingRimKeys.isEmpty
                    || !result.mismatchedRimKeys.isEmpty {
                    LabeledContent("Rim Issue") {
                        Text(
                            (result.missingRimKeys
                                + result.mismatchedRimKeys)
                                .joined(separator: ", ")
                        )
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tintStudySections(
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

    private func captureFullTintStudy() {
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
    private func configureFixedTintStudyContext() {
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
    private func captureAppKitTintEntry(
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
    private func capturedReducedTintOpacity(
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
    private func reducedTintOpacityGetterAvailable(
        on glass: NSGlassEffectView
    ) -> Bool {
        (glass as NSObject).responds(
            to: NSSelectorFromString("_tintOpacityReduced")
        )
    }

    @MainActor
    private func reducedTintOpacitySetterAvailable(
        on glass: NSGlassEffectView
    ) -> Bool {
        GlassLabTuning.supportsReducedTintOpacitySetter(on: glass)
    }

    @MainActor
    private func captureSemanticTintEntry(
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

    private func exportTintStudy() {
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

    @ViewBuilder
    private func semanticTransitionSections(
        state labState: GlassLabState
    ) -> some View {
        @Bindable var state = labState

        Section("Materialize Transition Probe") {
            Picker("Public Material", selection: $state.semanticUsage) {
                Text("Regular").tag(GlassLabSemanticUsage.regular)
                Text("Clear").tag(GlassLabSemanticUsage.clear)
            }
            .disabled(isCapturingMaterialize || isCapturingMaterializeStudy)

            Picker("Outer Animation", selection: $materializeAnimationMode) {
                ForEach(GlassLabMaterializeAnimationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isCapturingMaterialize || isCapturingMaterializeStudy)

            ColorPicker(
                "Glass Tint",
                selection: tintBinding,
                supportsOpacity: true
            )
            .disabled(isCapturingMaterialize || isCapturingMaterializeStudy)

            if materializeAnimationMode == .linear {
                labeledSlider(
                    "Linear Duration",
                    value: $materializeLinearDuration,
                    in: 1...8
                )
                .disabled(isCapturingMaterialize || isCapturingMaterializeStudy)
            }

            Text("`.materialize` owns the material mapping. This selector changes only the surrounding SwiftUI transaction so the system mapping can be separated from outer timing.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent("Current Endpoint") {
                Text(materializePresented ? "Presented" : "Removed")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Materialize In") {
                    runManualMaterializeTransition(.insertion)
                }
                .disabled(
                    materializePresented
                        || isCapturingMaterialize
                        || isCapturingMaterializeStudy
                )
                Button("Materialize Out") {
                    runManualMaterializeTransition(.removal)
                }
                .disabled(
                    !materializePresented
                        || isCapturingMaterialize
                        || isCapturingMaterializeStudy
                )
            }
        }

        Section("Capture Context") {
            Picker(
                "Capture Participation",
                selection: $materializeRequestedMain
            ) {
                Text("Main Off").tag(false)
                Text("Main On").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(isCapturingMaterialize || isCapturingMaterializeStudy)

            Picker(
                "Capture Appearance",
                selection: $materializeRequestedAppearance
            ) {
                ForEach(GlassLabTestAppearance.allCases) { appearance in
                    Text(appearance.rawValue).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isCapturingMaterialize || isCapturingMaterializeStudy)

            Picker(
                "Capture Backdrop",
                selection: $materializeRequestedBackdrop
            ) {
                ForEach(GlassLabBackdropMode.allCases) { backdrop in
                    Text(backdrop.rawValue).tag(backdrop)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isCapturingMaterialize || isCapturingMaterializeStudy)

            LabeledContent("Capture Target") {
                Text(
                    "Panel · Main "
                        + (materializeRequestedMain ? "On" : "Off")
                        + " · \(materializeRequestedAppearance.rawValue)"
                        + " · \(materializeRequestedBackdrop.rawValue) backdrop"
                        + " · 480×200@16 · margin 40"
                )
            }
            LabeledContent("Current Preview") {
                Text(
                    "\(state.windowHostType.rawValue)"
                        + " · requested Main "
                        + "\(state.isTestWindowMain ? "On" : "Off")"
                        + " · actual \(state.testWindow.isActuallyMain ? "On" : "Off")"
                        + " · \(state.testAppearance.rawValue)"
                        + " / \(state.testWindow.effectiveAppearanceName ?? "?")"
                        + " · \(state.testBackdrop.rawValue) backdrop"
                )
            }
            LabeledContent("Current Geometry") {
                Text(
                    "\(formatKnobValue(state.glassWidth))×"
                        + "\(formatKnobValue(state.glassHeight))"
                        + "@\(formatKnobValue(state.cornerRadius))"
                        + " · margin \(formatKnobValue(state.windowPadding))"
                )
                .monospacedDigit()
            }

            Text("Capture prepares this fixed target automatically and waits for actual Main/Key participation before sampling. Manual Materialize In/Out always uses the current Preview context and never rewrites it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Time-Series Capture") {
            HStack {
                Button("Capture Insertion") {
                    captureMaterializeTransition(.insertion)
                }
                Button("Capture Removal") {
                    captureMaterializeTransition(.removal)
                }
            }
            .disabled(isCapturingMaterialize || isCapturingMaterializeStudy)

            Text("Each run records a settled start, the first post-trigger frame, then 0.125/0.25/0.5/0.75/0.875/1.0 samples. Every sample contains model and presentation trees, resolved filters/effects, and recursively attached CAAnimation metadata.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if isCapturingMaterialize {
                ProgressView(materializeCaptureStatus ?? "Capturing Materialize…")
                    .controlSize(.small)
            } else if let materializeCaptureStatus {
                Text(materializeCaptureStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("P1 Full Coverage Matrix") {
            Button(
                isCapturingMaterializeStudy
                    ? "Capturing 64-Run Matrix…"
                    : "Capture Full P1 Matrix (64 Runs)"
            ) {
                captureFullMaterializeStudy()
            }
            .disabled(isCapturingMaterialize || isCapturingMaterializeStudy)

            Text("Runs Regular/Clear × Main Off/On × Aqua/DarkAqua × Light/Dark backdrop × None/Coral-50 Tint × Insertion/Removal with a one-second linear transaction. Every run keeps the real test window non-key and verifies its requested Main and effective appearance before sampling.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if isCapturingMaterializeStudy {
                ProgressView(
                    materializeStudyStatus
                        ?? "Capturing full P1 Materialize matrix…"
                )
                .controlSize(.small)
            } else if let materializeStudyStatus {
                Text(materializeStudyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let document = materializeStudyDocument {
                LabeledContent("Transitions") {
                    Text(String(document.transitions.count))
                        .monospacedDigit()
                }
                LabeledContent("Samples") {
                    Text(
                        String(
                            document.transitions.reduce(0) {
                                $0 + $1.samples.count
                            }
                        )
                    )
                    .monospacedDigit()
                }
                HStack {
                    Button("Copy Matrix Report") {
                        state.reportOutput = document.report
                        copyToPasteboard(document.report)
                    }
                    Button("Export Matrix JSON") {
                        exportMaterializeStudy()
                    }
                }
            }
        }

        if let capture = materializeCapture {
            Section("Latest Capture") {
                LabeledContent("Usage") {
                    Text(capture.usage)
                }
                LabeledContent("Direction") {
                    Text(capture.direction.rawValue)
                }
                LabeledContent("Animation") {
                    Text(capture.animationMode.rawValue)
                }
                LabeledContent("Samples") {
                    Text(String(capture.samples.count)).monospacedDigit()
                }
                LabeledContent("Attached Animations") {
                    Text(
                        String(
                            capture.samples.map {
                                $0.snapshot.animations.count
                            }.max() ?? 0
                        )
                    )
                    .monospacedDigit()
                }
                HStack {
                    Button("Copy Capture Report") {
                        copyMaterializeCaptureReport()
                    }
                    Button("Export Capture JSON") {
                        exportMaterializeCapture()
                    }
                }
                ScrollView(.horizontal) {
                    Text(capture.report)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
    }

    @ViewBuilder
    private func generalWindowSections(state labState: GlassLabState) -> some View {
        @Bindable var state = labState

        Section("Test Window Context") {
            Toggle(isOn: $state.isTestWindowVisible) {
                LabRowLabel(
                    "Show Test Window",
                    description: "The only glass surface in the lab. The Playground window remains the control and restoration anchor."
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Host Type", selection: $state.windowHostType) {
                    ForEach(GlassLabWindowHostType.allCases) { hostType in
                        Text(hostType.rawValue).tag(hostType)
                    }
                }
                .pickerStyle(.segmented)
                Text(state.rendererMode == .recipe
                    ? "Changing Panel ↔ Window recreates the host while preserving Size, Recipe, and Overrides. Window uses a normal titled NSWindow with the former Canvas backdrop; Panel remains transparent and non-activating."
                    : "Changing Panel ↔ Window recreates the SwiftUI semantic surface while preserving Size and Usage. Window supplies the colorful Canvas backdrop; Panel remains transparent and non-activating.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Window Appearance", selection: $state.testAppearance) {
                    ForEach(GlassLabTestAppearance.allCases) { appearance in
                        Text(appearance.rawValue).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Backdrop", selection: $state.testBackdrop) {
                    ForEach(GlassLabBackdropMode.allCases) { backdrop in
                        Text(backdrop.rawValue).tag(backdrop)
                    }
                }
                .pickerStyle(.segmented)
                Text("Window Appearance forces Aqua/DarkAqua on this test window only. Backdrop Light/Dark draws a fixed neutral sRGB surface below the Glass; Ambient preserves the transparent Panel or colorful Window behavior. These are independent public-environment axes and do not write `_adaptiveAppearance`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disabled(!state.isTestWindowVisible)

            Toggle(isOn: $state.isTestWindowMain) {
                LabRowLabel(
                    "Main Window",
                    description: state.rendererMode == .recipe
                        ? "Off guarantees the test surface is neither key nor main and selects the flat branch. On makes it main-only and selects the active branch while this control window remains key."
                        : "Off guarantees the semantic host is neither key nor main. On makes it main-only while this control window remains key, so Usage context changes can be inspected without conflating them with focus."
                )
            }
            .disabled(!state.isTestWindowVisible)

            VStack(alignment: .leading, spacing: 6) {
                labeledSlider("Window Margin", value: $state.windowPadding, in: 0...120)
                Text("Area around the glass inside the test window. A window hard-clips at its backing surface, so shadow, ring shadow, and outer refraction need this room; 0 reproduces the square-clipped zero-margin Panel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disabled(!state.isTestWindowVisible)

            Text(state.rendererMode == .recipe
                ? "The controlled matrix ruled out window class, style, transparency, native shadow, and level as direct Recipe selectors. Host Type remains useful for visual clipping and window-behavior experiments; real key/main participation is the Recipe axis."
                : "Semantic Usage owns a larger SwiftUI/Core Animation composition. Host and real key/main participation remain available as controlled environment inputs, but their semantic effects have not yet been folded into the NSGlass Recipe Matrix.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        Section("Diagnostics") {
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

    // MARK: Controls

    private func shaderGroupControls(
        _ group: GlassLabTuning.ShaderGroup,
        knobs: [GlassLabTuning.Knob],
        state labState: GlassLabState,
        snapshot: LiveReadoutSnapshot?
    ) -> some View {
        @Bindable var state = labState
        let colors = GlassLabTuning.shaderColorKeys.filter {
            GlassLabTuning.shaderGroup(forKey: $0.key) == group
        }
        let points = GlassLabTuning.shaderPointKeys.filter {
            GlassLabTuning.shaderGroup(forKey: $0.key) == group
        }
        let strings = GlassLabTuning.shaderReadOnlyKeys.filter {
            GlassLabTuning.shaderGroup(forKey: $0.key) == group
        }
        let isEditable = state.shaderOverridesEnabled && snapshot?.shaderInputKeys != nil

        return Group {
            ForEach(colors, id: \.key) { descriptor in
                colorControl(
                    descriptor.label,
                    key: descriptor.key,
                    overrides: $state.shaderColorOverrides,
                    liveValue: snapshot?.shaderColors[descriptor.key],
                    missingValueLabel: shaderMissingValueLabel(for: descriptor.key, in: snapshot),
                    isEditable: isEditable
                )
            }
            ForEach(points, id: \.key) { descriptor in
                pointControl(
                    descriptor.label,
                    key: descriptor.key,
                    overrides: $state.shaderPointOverrides,
                    liveValue: snapshot?.shaderPoints[descriptor.key],
                    missingValueLabel: shaderMissingValueLabel(for: descriptor.key, in: snapshot),
                    isEditable: isEditable
                )
            }
            // Preserve the group's curated/key order. Splitting low-signal
            // controls into a trailing DisclosureGroup broke related pairs by
            // moving one member away from the other.
            ForEach(knobs, id: \.key) { knob in
                knobControl(
                    knob,
                    overrides: $state.shaderOverrides,
                    liveValue: snapshot?.shader[knob.key],
                    missingValueLabel: shaderMissingValueLabel(for: knob.key, in: snapshot),
                    signalTag: matrixSignalTag(
                        for: knob,
                        hasSnapshot: snapshot != nil,
                        inputKeys: snapshot?.shaderInputKeys,
                        liveValue: snapshot?.shader[knob.key]
                    ),
                    metadata: inspectorShaderMetadata[knob.key],
                    isEditable: isEditable,
                    stampLive: { value in
                        stampLiveShaderValue(value, forKey: knob.key)
                    }
                )
            }
            ForEach(strings, id: \.key) { descriptor in
                knobRowScaffold(
                    title: descriptor.label,
                    signalTag: nil,
                    caption: "Read-only",
                    help: "\(descriptor.key)\nNames a source-layer dependency rather than a numeric material parameter."
                ) {
                    Text(
                        snapshot?.shaderStrings[descriptor.key]
                            ?? shaderMissingValueLabel(for: descriptor.key, in: snapshot)
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: 360, alignment: .trailing)
                }
            }
        }
    }

    private func highlightGroupControls(
        _ group: GlassLabTuning.HighlightGroup,
        state labState: GlassLabState,
        snapshot: LiveReadoutSnapshot?
    ) -> some View {
        @Bindable var state = labState
        let knobs = GlassLabTuning.highlightKnobs.filter {
            GlassLabTuning.highlightGroup(forKey: $0.key) == group
        }
        let colors = GlassLabTuning.highlightColorKeys.filter {
            GlassLabTuning.highlightGroup(forKey: $0.key) == group
        }
        let isEditable = state.highlightOverridesEnabled && snapshot?.highlightInputKeys != nil

        return Group {
            if group == .gateAndShape {
                Text("A separate CASDFKeyFillHighlightEffect pass. Variants 4, 13, and 14 omit it; real key-or-main participation primarily changes its layer-opacity gate and color alphas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(colors, id: \.key) { descriptor in
                colorControl(
                    descriptor.label,
                    key: descriptor.key,
                    overrides: $state.highlightColorOverrides,
                    liveValue: snapshot?.highlightColors[descriptor.key],
                    missingValueLabel: highlightMissingValueLabel(for: descriptor.key, in: snapshot),
                    isEditable: isEditable
                )
            }
            ForEach(knobs, id: \.key) { knob in
                knobControl(
                    knob,
                    overrides: $state.highlightOverrides,
                    liveValue: snapshot?.highlight[knob.key],
                    missingValueLabel: highlightMissingValueLabel(for: knob.key, in: snapshot),
                    signalTag: matrixSignalTag(
                        for: knob,
                        hasSnapshot: snapshot != nil,
                        inputKeys: snapshot?.highlightInputKeys,
                        liveValue: snapshot?.highlight[knob.key]
                    ),
                    metadata: inspectorHighlightMetadata[knob.key],
                    isEditable: isEditable,
                    stampLive: { value in
                        stampLiveHighlightValue(value, forKey: knob.key)
                    }
                )
            }
        }
    }

    private func geometryControls(
        state labState: GlassLabState,
        snapshot: LiveReadoutSnapshot?,
        keys: Set<String>? = nil
    ) -> some View {
        @Bindable var state = labState
        let knobs = GlassLabTuning.geometryKnobs.filter {
            keys?.contains($0.key) ?? true
        }
        let isEditable = state.shaderOverridesEnabled && snapshot != nil

        return Group {
            Text("Layer geometry, not filter inputs. Minimum uses -10000 as an unbounded runtime sentinel. At 480×200 the active branch resolves margin 70 / reach ~40; the neither-key-nor-main Panel resolves 0.5 / 1.5.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(knobs, id: \.key) { knob in
                knobControl(
                    knob,
                    overrides: $state.layerGeometryOverrides,
                    liveValue: snapshot?.geometry[knob.key],
                    missingValueLabel: geometryMissingValueLabel(for: knob.key, in: snapshot),
                    signalTag: matrixSignalTag(
                        for: knob,
                        hasSnapshot: snapshot != nil,
                        inputKeys: snapshot?.geometryKeys,
                        liveValue: snapshot?.geometry[knob.key]
                    ),
                    metadata: nil,
                    isEditable: isEditable,
                    stampLive: { value in
                        stampLiveGeometryValue(value, forKey: knob.key)
                    }
                )
            }
        }
    }

    /// Runtime availability already appears in the value column as nil,
    /// Absent, or Pass Absent. Only a present low-signal value needs an extra
    /// tag to explain that the Matrix classified it as constant.
    private func matrixSignalTag(
        for knob: GlassLabTuning.Knob,
        hasSnapshot: Bool,
        inputKeys: Set<String>?,
        liveValue: Double?
    ) -> String? {
        guard GlassLabTuning.isMatrixLowSignal(knob),
              hasSnapshot,
              let inputKeys,
              inputKeys.contains(knob.key),
              liveValue != nil else { return nil }
        return "Constant"
    }

    /// The caption carries only the effective bounds; the range's provenance
    /// lives in the row's hover help. The full-width tilde keeps negative
    /// bounds readable ("-300 ～ 0").
    private func rangeCaption(_ range: ClosedRange<Double>) -> String {
        "\(formatRangeValue(range.lowerBound)) ～ \(formatRangeValue(range.upperBound))"
    }

    /// The row shows only the essentials; the tooltip carries the private
    /// input key, the effective range, and the range's provenance.
    private func knobHelp(
        _ knob: GlassLabTuning.Knob,
        range: ClosedRange<Double>?,
        source: String?,
        signalTag: String?,
        extra: String? = nil
    ) -> String {
        var lines = [knob.key]
        if let range {
            var line = "Range \(formatRangeValue(range.lowerBound))…\(formatRangeValue(range.upperBound))"
            if let source { line += " — \(rangeSourceHelp(source))" }
            lines.append(line)
        }
        if signalTag != nil {
            lines.append("Constant across every sampled Recipe in the measured Matrix.")
        }
        if let extra { lines.append(extra) }
        return lines.joined(separator: "\n")
    }

    private func knobValueLabel(_ value: String, isOverridden: Bool) -> some View {
        Text(value)
            .font(.callout.monospacedDigit())
            .foregroundStyle(isOverridden ? Color.orange : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: InspectorLayout.valueWidth, alignment: .trailing)
            .textSelection(.enabled)
    }

    private func rangeSourceHelp(_ source: String) -> String {
        let base: String
        if source.hasPrefix("System") {
            base = "Core Animation metadata"
        } else if source.hasPrefix("Recipe") {
            base = "measured Recipe Matrix envelope"
        } else if source.hasPrefix("Angle") {
            base = "semantic angle bounds in radians"
        } else if source.hasPrefix("CGColor") {
            base = "the alpha component of a CGColor input"
        } else {
            base = "authoring fallback for a field without a useful system or measured range"
        }
        return source.contains("+Current")
            ? base + ", expanded to include the current value"
            : base
    }

    private func labeledSlider(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: value, in: range)
                .frame(width: InspectorLayout.sliderWidth)
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: InspectorLayout.valueWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func knobControl(
        _ knob: GlassLabTuning.Knob,
        overrides: Binding<[String: Double]>,
        liveValue: Double?,
        missingValueLabel: String,
        signalTag: String?,
        metadata: GlassLabTuning.AttributeMetadata?,
        isEditable: Bool,
        stampLive: @escaping (Double) -> Void
    ) -> some View {
        switch GlassLabTuning.resolvedControlKind(for: knob, metadata: metadata) {
        case .boolean:
            booleanKnob(
                knob,
                overrides: overrides,
                liveValue: liveValue,
                missingValueLabel: missingValueLabel,
                signalTag: signalTag,
                isEditable: isEditable
            )
        case .sentinel(let sentinel):
            sentinelKnob(
                knob,
                sentinel: sentinel,
                overrides: overrides,
                liveValue: liveValue,
                missingValueLabel: missingValueLabel,
                signalTag: signalTag,
                isEditable: isEditable,
                stampLive: stampLive
            )
        case .scalar, .percentage, .angle:
            sliderKnob(
                knob,
                overrides: overrides,
                liveValue: liveValue,
                missingValueLabel: missingValueLabel,
                signalTag: signalTag,
                metadata: metadata,
                isEditable: isEditable,
                stampLive: stampLive
            )
        }
    }

    private func sliderKnob(
        _ knob: GlassLabTuning.Knob,
        overrides: Binding<[String: Double]>,
        liveValue: Double?,
        missingValueLabel: String,
        signalTag: String?,
        metadata: GlassLabTuning.AttributeMetadata?,
        isEditable: Bool,
        stampLive: @escaping (Double) -> Void
    ) -> some View {
        let resolvedRange = GlassLabTuning.resolvedSliderRange(
            for: knob,
            metadata: metadata,
            liveValue: liveValue,
            overrideValue: overrides.wrappedValue[knob.key]
        )
        return GlassKnobSliderRow(
            knob: knob,
            range: resolvedRange.range,
            caption: rangeCaption(resolvedRange.range),
            help: knobHelp(
                knob,
                range: resolvedRange.range,
                source: resolvedRange.source,
                signalTag: signalTag
            ),
            signalTag: signalTag,
            liveValue: liveValue,
            missingValueLabel: missingValueLabel,
            isEditable: isEditable,
            sentinel: nil,
            overrideValue: overrideBinding(for: knob.key, in: overrides),
            stampLive: stampLive
        )
    }

    private func booleanKnob(
        _ knob: GlassLabTuning.Knob,
        overrides: Binding<[String: Double]>,
        liveValue: Double?,
        missingValueLabel: String,
        signalTag: String?,
        isEditable: Bool
    ) -> some View {
        let help = knobHelp(
            knob,
            range: nil,
            source: nil,
            signalTag: signalTag,
            extra: "Boolean input declared by Core Animation."
        )
        return knobRowScaffold(
            title: knob.label,
            signalTag: signalTag,
            caption: "Boolean",
            help: help
        ) {
            knobValueLabel(
                liveValue.map { $0 == 0 ? "Off" : "On" } ?? missingValueLabel,
                isOverridden: overrides.wrappedValue[knob.key] != nil
            )
            Toggle(isOn: Binding {
                    (overrides.wrappedValue[knob.key] ?? liveValue ?? knob.fallback) != 0
                } set: { enabled in
                    overrides.wrappedValue[knob.key] = enabled ? 1 : 0
                }) { EmptyView() }
            .labelsHidden()
            .disabled(!isEditable)
        }
    }

    private func sentinelKnob(
        _ knob: GlassLabTuning.Knob,
        sentinel: Double,
        overrides: Binding<[String: Double]>,
        liveValue: Double?,
        missingValueLabel: String,
        signalTag: String?,
        isEditable: Bool,
        stampLive: @escaping (Double) -> Void
    ) -> some View {
        GlassKnobSliderRow(
            knob: knob,
            range: knob.range,
            caption: rangeCaption(knob.range),
            help: knobHelp(
                knob,
                range: knob.range,
                source: "Authoring",
                signalTag: signalTag,
                extra: "The Recipe treats \(String(format: "%g", sentinel)) as an unbounded sentinel; Unbounded toggles it."
            ),
            signalTag: signalTag,
            liveValue: liveValue,
            missingValueLabel: missingValueLabel,
            isEditable: isEditable,
            sentinel: sentinel,
            overrideValue: overrideBinding(for: knob.key, in: overrides),
            stampLive: stampLive
        )
    }

    private func overrideBinding(
        for key: String,
        in overrides: Binding<[String: Double]>
    ) -> Binding<Double?> {
        Binding {
            overrides.wrappedValue[key]
        } set: { value in
            overrides.wrappedValue[key] = value
        }
    }

    private func vibrantMatrixBooleanBinding(
        slotID: String,
        key: String,
        liveValue: GlassLabTuning.VibrantBooleanOverrideValue
    ) -> Binding<GlassLabTuning.VibrantBooleanOverrideValue> {
        Binding {
            state.vibrantMatrixOverrides[slotID]?.booleanValues[key] ?? liveValue
        } set: { value in
            guard var payload = state.vibrantMatrixOverrides[slotID] else { return }
            payload.booleanValues[key] = value
            state.vibrantMatrixOverrides[slotID] = payload
        }
    }

    private func vibrantMatrixCoefficientBinding(
        slotID: String,
        index: Int,
        liveValue: Double
    ) -> Binding<Double> {
        Binding {
            guard let values = state.vibrantMatrixOverrides[slotID]?
                .matrixCoefficients,
                values.indices.contains(index) else { return liveValue }
            return values[index]
        } set: { value in
            guard value.isFinite,
                  var payload = state.vibrantMatrixOverrides[slotID],
                  payload.matrixCoefficients.indices.contains(index) else { return }
            payload.matrixCoefficients[index] = value
            state.vibrantMatrixOverrides[slotID] = payload
        }
    }

    private func colorControl(
        _ label: String,
        key: String,
        overrides: Binding<[String: NSColor]>,
        liveValue: NSColor?,
        missingValueLabel: String,
        isEditable: Bool
    ) -> some View {
        knobRowScaffold(
            title: label,
            signalTag: nil,
            caption: "CGColor · " + (liveValue.map(formatColor) ?? missingValueLabel),
            help: "\(key)\nCGColor input declared by Core Animation.",
            isCaptionHighlighted: overrides.wrappedValue[key] != nil
        ) {
            ColorPicker(
                "",
                selection: Binding {
                    Color(overrides.wrappedValue[key] ?? liveValue ?? .clear)
                } set: { color in
                    overrides.wrappedValue[key] = NSColor(color)
                },
                supportsOpacity: true
            )
            .labelsHidden()
            .disabled(!isEditable)
        }
    }

    private func pointControl(
        _ label: String,
        key: String,
        overrides: Binding<[String: CGPoint]>,
        liveValue: CGPoint?,
        missingValueLabel: String,
        isEditable: Bool
    ) -> some View {
        let current = overrides.wrappedValue[key] ?? liveValue ?? .zero
        return knobRowScaffold(
            title: label,
            signalTag: nil,
            caption: "CGPoint · " + (liveValue.map {
                "(\(formatKnobValue($0.x)), \(formatKnobValue($0.y)))"
            } ?? missingValueLabel),
            help: "\(key)\nCGPoint input with unbounded numeric components.",
            isCaptionHighlighted: overrides.wrappedValue[key] != nil
        ) {
            TextField("X", value: pointComponentBinding(key: key, axis: \.x, overrides: overrides, fallback: current), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
                .disabled(!isEditable)
            TextField("Y", value: pointComponentBinding(key: key, axis: \.y, overrides: overrides, fallback: current), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
                .disabled(!isEditable)
        }
    }

    private func pointComponentBinding(
        key: String,
        axis: WritableKeyPath<CGPoint, CGFloat>,
        overrides: Binding<[String: CGPoint]>,
        fallback: CGPoint
    ) -> Binding<Double> {
        Binding {
            Double((overrides.wrappedValue[key] ?? fallback)[keyPath: axis])
        } set: { value in
            var point = overrides.wrappedValue[key] ?? fallback
            point[keyPath: axis] = CGFloat(value)
            overrides.wrappedValue[key] = point
        }
    }

    private func formatColor(_ color: NSColor) -> String {
        guard let value = color.usingColorSpace(.sRGB) else { return color.description }
        return String(
            format: "%.2f %.2f %.2f %.2f",
            value.redComponent,
            value.greenComponent,
            value.blueComponent,
            value.alphaComponent
        )
    }

    private func formatKnobValue(_ value: Double) -> String {
        String(format: "%.4g", value)
    }

    private func formatRangeValue(_ value: Double) -> String {
        String(format: "%.3g", value)
    }

    private struct LiveReadoutSnapshot: Equatable {
        /// nil means the entire glassBackground pass is absent. Otherwise the
        /// set includes declared inputs even when their current value is nil.
        let shaderInputKeys: Set<String>?
        let shader: [String: Double]
        let shaderColors: [String: NSColor]
        let shaderPoints: [String: CGPoint]
        let shaderStrings: [String: String]
        /// nil means the entire CASDFKeyFillHighlightEffect pass is absent.
        let highlightInputKeys: Set<String>?
        let highlight: [String: Double]
        let highlightColors: [String: NSColor]
        let geometryKeys: Set<String>
        let geometry: [String: Double]
    }

    private struct ForegroundProbeReport: Equatable {
        let requestedValue: String
        let before: GlassLabTuning.ForegroundAberrationProbeObservation
        let immediate: GlassLabTuning.ForegroundAberrationProbeObservation
        let settled: GlassLabTuning.ForegroundAberrationProbeObservation

        var objectWasReplaced: Bool {
            before.objectIdentity != settled.objectIdentity
        }
    }

    private enum VibrantMatrixMutationKind: String {
        case booleans = "Boolean vector"
        case matrix = "Matrix coefficient"
    }

    private struct VibrantMatrixMutationReport {
        let kind: VibrantMatrixMutationKind
        let before: GlassLabTuning.VibrantColorMatrixProbeObservation
        let immediate: GlassLabTuning.VibrantColorMatrixProbeObservation
        let settled: GlassLabTuning.VibrantColorMatrixProbeObservation
        let peerBefore: GlassLabTuning.VibrantColorMatrixProbeObservation
        let peerSettled: GlassLabTuning.VibrantColorMatrixProbeObservation
        let reset: GlassLabTuning.VibrantColorMatrixProbeObservation
        let peerReset: GlassLabTuning.VibrantColorMatrixProbeObservation

        private var expectedBooleanValues: [String: String] {
            before.modelBooleanValues.mapValues { value in
                value == "1" ? "0" : "1"
            }
        }

        var modelWriteAccepted: Bool {
            switch kind {
            case .booleans:
                return immediate.modelBooleanValues == expectedBooleanValues
                    && settled.modelBooleanValues == expectedBooleanValues
                    && immediate.modelMatrixDigest == before.modelMatrixDigest
                    && settled.modelMatrixDigest == before.modelMatrixDigest
            case .matrix:
                let expected = before.modelMatrixFirstCoefficient + 0.25
                return abs(immediate.modelMatrixFirstCoefficient - expected) < 0.000_01
                    && abs(settled.modelMatrixFirstCoefficient - expected) < 0.000_01
                    && immediate.modelMatrixDigest != before.modelMatrixDigest
                    && settled.modelMatrixDigest == immediate.modelMatrixDigest
                    && settled.modelBooleanValues == before.modelBooleanValues
            }
        }

        var presentationWriteAccepted: Bool {
            guard settled.presentationMatrixDigest != nil else { return false }
            switch kind {
            case .booleans:
                return settled.presentationBooleanValues == expectedBooleanValues
                    && settled.presentationMatrixDigest == before.modelMatrixDigest
            case .matrix:
                guard let coefficient = settled.presentationMatrixFirstCoefficient else {
                    return false
                }
                let expected = before.modelMatrixFirstCoefficient + 0.25
                return abs(coefficient - expected) < 0.000_01
                    && settled.presentationMatrixDigest == settled.modelMatrixDigest
                    && settled.presentationBooleanValues == before.modelBooleanValues
            }
        }

        var peerStayedIndependent: Bool {
            peerSettled.modelValueSignature == peerBefore.modelValueSignature
                && peerSettled.presentationValueSignature
                    == peerBefore.presentationValueSignature
        }

        var recipeResetAccepted: Bool {
            reset.modelValueSignature == before.modelValueSignature
                && reset.presentationValueSignature == before.presentationValueSignature
                && peerReset.modelValueSignature == peerBefore.modelValueSignature
                && peerReset.presentationValueSignature
                    == peerBefore.presentationValueSignature
        }

        var objectWasReplaced: Bool {
            before.objectIdentity != settled.objectIdentity
        }

        var accepted: Bool {
            modelWriteAccepted
                && presentationWriteAccepted
                && peerStayedIndependent
                && recipeResetAccepted
                && settled.animationKeyPaths.isEmpty
        }
    }

    private struct VibrantMatrixCaseReport: Identifiable {
        let variant: Int
        let requestedMain: Bool
        let ordinal: Int
        let booleanMutation: VibrantMatrixMutationReport
        let matrixMutation: VibrantMatrixMutationReport

        var id: String {
            "\(variant)|\(requestedMain)|\(ordinal)"
        }

        var accepted: Bool {
            booleanMutation.accepted && matrixMutation.accepted
        }
    }

    private struct PassInventoryItem: Identifiable {
        let record: GlassLabTuning.PassAuditPassRecord
        let channel: String
        let family: String
        let ordinal: Int
        let familyCount: Int

        var id: String { record.id }
        var slotID: String { "\(record.layerPath)|\(record.location)" }
    }

    private func passInventoryItems(
        _ snapshot: GlassLabTuning.PassAuditSnapshot
    ) -> [PassInventoryItem] {
        let records = snapshot.passes.values.sorted { lhs, rhs in
            let left = [
                String(passChannelRank(passChannel(lhs))),
                passChannel(lhs),
                passFamily(lhs),
                lhs.layerPath,
                lhs.location,
                lhs.id,
            ].joined(separator: "|")
            let right = [
                String(passChannelRank(passChannel(rhs))),
                passChannel(rhs),
                passFamily(rhs),
                rhs.layerPath,
                rhs.location,
                rhs.id,
            ].joined(separator: "|")
            return left < right
        }
        let counts = Dictionary(grouping: records) {
            "\(passChannel($0))|\(passFamily($0))"
        }.mapValues(\.count)
        var nextOrdinal: [String: Int] = [:]
        return records.map { record in
            let channel = passChannel(record)
            let family = passFamily(record)
            let group = "\(channel)|\(family)"
            let ordinal = (nextOrdinal[group] ?? 0) + 1
            nextOrdinal[group] = ordinal
            return PassInventoryItem(
                record: record,
                channel: channel,
                family: family,
                ordinal: ordinal,
                familyCount: counts[group] ?? 1
            )
        }
    }

    private func passChannel(_ pass: GlassLabTuning.PassAuditPassRecord) -> String {
        String(pass.location.prefix { $0 != "[" })
    }

    private func passFamily(_ pass: GlassLabTuning.PassAuditPassRecord) -> String {
        pass.name ?? pass.objectClass
    }

    private func passChannelRank(_ channel: String) -> Int {
        switch channel {
        case "filters": 0
        case "backgroundFilters": 1
        case "compositingFilter": 2
        case "effect": 3
        default: 4
        }
    }

    private func passInventorySectionTitle(_ item: PassInventoryItem) -> String {
        let instance = item.familyCount > 1
            ? " · \(item.ordinal)/\(item.familyCount)"
            : ""
        return "\(item.channel) · \(item.family)\(instance)"
    }

    private func selectedPassItem(
        in items: [PassInventoryItem]
    ) -> PassInventoryItem? {
        if let selectedPassSlotID,
           let selected = items.first(where: { $0.slotID == selectedPassSlotID }) {
            return selected
        }
        return items.first(where: { $0.family == "glassBackground" }) ?? items.first
    }

    private func passMutationContractSummary(
        for item: PassInventoryItem
    ) -> String {
        let classifications = item.record.properties.map { key, property in
            GlassLabTuning.classifyPassProperty(
                property,
                key: key,
                in: item.record
            )
        }
        let accepted = classifications.filter(\.isMutationAccepted).count
        let readOnly = classifications.count - accepted
        if classifications.isEmpty {
            switch GlassLabTuning.passMutationFamily(for: item.record) {
            case .compositingMode:
                return "Read-only · discrete mode audit required"
            default:
                return "Read-only · no declared properties"
            }
        }
        if readOnly == 0 {
            return "\(accepted) accepted"
        }
        if accepted > 0 {
            return "\(accepted) accepted · \(readOnly) read-only"
        }
        return "\(readOnly) read-only · mutation audit required"
    }

    private func passState(
        for item: PassInventoryItem,
        state: GlassLabState
    ) -> String {
        if replacedPassSlots.contains(item.slotID) {
            return "Replaced"
        }
        if item.family == "glassBackground", state.shaderOverridesEnabled {
            return "Overridden"
        }
        if item.family == "CASDFOutputEffect", state.shaderOverridesEnabled {
            return "Overridden"
        }
        if item.record.objectClass == "CASDFKeyFillHighlightEffect",
           state.highlightOverridesEnabled {
            return "Overridden"
        }
        if item.family == "vibrantColorMatrix",
           state.vibrantMatrixOverridesEnabled,
           state.vibrantMatrixOverrides[item.slotID] != nil {
            return "Overridden"
        }
        return "Present"
    }

    private func passPropertyMetadata(_ attributes: [String: String]) -> String {
        attributes.keys.sorted().map { key in
            "\(key)=\(attributes[key]!)"
        }.joined(separator: " · ")
    }

    private var foregroundProbeContextIsReady: Bool {
        state.rendererMode == .recipe
            && state.variant == 14
            && state.subvariant.isEmpty
            && !state.isSubdued
            && state.windowHostType == .panel
            && !state.isTestWindowMain
            && state.isTestWindowVisible
            && abs(state.glassWidth - 480) < 0.001
            && abs(state.glassHeight - 200) < 0.001
            && abs(state.cornerRadius - 16) < 0.001
            && abs(state.windowPadding - 40) < 0.001
            && !state.shaderOverridesEnabled
            && !state.highlightOverridesEnabled
            && !state.vibrantMatrixOverridesEnabled
    }

    /// Establishes the exact accepted recursive-audit context. The explicit
    /// rebuild is part of the probe contract: a previous private filter write
    /// cannot be reset reliably by writing the old scalar back.
    private func prepareForegroundProbeBaseline() {
        cancelForegroundProbe(clearReport: true)
        state.shaderOverridesEnabled = false
        state.highlightOverridesEnabled = false
        state.vibrantMatrixOverridesEnabled = false
        shaderOverrideBaseline = nil
        highlightOverrideBaseline = nil
        vibrantMatrixOverrideBaseline = nil
        clearShaderOverridePayload()
        clearHighlightOverridePayload()
        clearVibrantMatrixOverridePayload()

        state.rendererMode = .recipe
        state.variant = 14
        state.subvariant = ""
        state.isSubdued = false
        state.glassWidth = 480
        state.glassHeight = 200
        state.cornerRadius = 16
        state.windowHostType = .panel
        state.isTestWindowMain = false
        state.windowPadding = 40
        state.isTestWindowVisible = true
        state.testWindow.rebuildGlass(with: state)
        foregroundProbeStatus = "Fresh Variant 14 baseline requested; wait for the pass inventory to settle."
        scheduleLiveReadoutRefresh(refreshSchema: true)
    }

    private func runForegroundAberrationProbe(
        value: Double?,
        item: PassInventoryItem
    ) {
        guard foregroundProbeContextIsReady else {
            foregroundProbeStatus = "The fixed Variant 14 baseline is not ready."
            return
        }
        guard NSApp.isActive,
              !state.testWindow.isActuallyKey,
              !state.testWindow.isActuallyMain else {
            foregroundProbeStatus = "The app must be active while the test Panel remains neither key nor main."
            return
        }

        cancelForegroundProbe(clearReport: true)
        isForegroundProbeRunning = true
        let requestedValue = value.map(formatKnobValue) ?? "nil"
        let slotID = item.slotID
        foregroundProbeStatus = "Rebuilding a fresh baseline before requesting \(requestedValue)."
        state.testWindow.rebuildGlass(with: state)

        foregroundProbeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  foregroundProbeContextIsReady,
                  let glass = selectedReadoutGlass,
                  let capture = GlassLabTuning.captureLivePassAudit(from: glass),
                  let pass = capture.snapshot.passes.values.first(where: {
                      "\($0.layerPath)|\($0.location)" == slotID
                          && $0.name == "glassForeground"
                  }),
                  let before = GlassLabTuning.captureForegroundAberrationAmountProbe(
                      from: glass,
                      matching: pass
                  ) else {
                finishForegroundProbeFailure(
                    "The selected glassForeground slot was not available after reconstruction."
                )
                return
            }

            guard GlassLabTuning.applyForegroundAberrationAmountProbe(
                value,
                to: glass,
                matching: pass
            ),
            let immediate = GlassLabTuning.captureForegroundAberrationAmountProbe(
                from: glass,
                matching: pass
            ) else {
                finishForegroundProbeFailure(
                    "The owning-layer write did not produce an immediate readable target."
                )
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let settledCapture = GlassLabTuning.captureLivePassAudit(from: glass),
                  let settledPass = settledCapture.snapshot.passes.values.first(where: {
                      "\($0.layerPath)|\($0.location)" == slotID
                          && $0.name == "glassForeground"
                  }),
                  let settled = GlassLabTuning.captureForegroundAberrationAmountProbe(
                      from: glass,
                      matching: settledPass
                  ) else {
                finishForegroundProbeFailure(
                    "The selected pass disappeared during the 350 ms settling window."
                )
                return
            }

            foregroundProbeReport = ForegroundProbeReport(
                requestedValue: requestedValue,
                before: before,
                immediate: immediate,
                settled: settled
            )
            foregroundProbeStatus = "Probe complete. Use Rebuild / Reset before unrelated experiments."
            isForegroundProbeRunning = false
            foregroundProbeTask = nil
            publishPassInventorySnapshot()
        }
    }

    private func resetForegroundAberrationProbe() {
        cancelForegroundProbe(clearReport: true)
        state.testWindow.rebuildGlass(with: state)
        foregroundProbeStatus = "The private filter tree was rebuilt from the current Recipe."
        scheduleLiveReadoutRefresh(refreshSchema: true)
    }

    private func cancelForegroundProbe(clearReport: Bool) {
        foregroundProbeTask?.cancel()
        foregroundProbeTask = nil
        isForegroundProbeRunning = false
        if clearReport {
            foregroundProbeReport = nil
            foregroundProbeStatus = nil
        }
    }

    private func finishForegroundProbeFailure(_ message: String) {
        foregroundProbeReport = nil
        foregroundProbeStatus = message
        isForegroundProbeRunning = false
        foregroundProbeTask = nil
        scheduleLiveReadoutRefresh()
    }

    private func probeValue(
        _ observation: GlassLabTuning.ForegroundAberrationProbeObservation,
        presentation: Bool
    ) -> String {
        if presentation {
            return observation.presentationValue ?? observation.presentationState
        }
        return observation.modelValue ?? observation.modelState
    }

    private func foregroundProbeReportText(_ report: ForegroundProbeReport) -> String {
        func observationLine(
            _ label: String,
            _ observation: GlassLabTuning.ForegroundAberrationProbeObservation
        ) -> String {
            let animations = observation.animationKeyPaths.isEmpty
                ? "none"
                : observation.animationKeyPaths.joined(separator: ",")
            return "\(label)"
                + " model=\(probeValue(observation, presentation: false))"
                + " presentation=\(probeValue(observation, presentation: true))"
                + " opacity=\(formatKnobValue(observation.layerOpacity))"
                + " hidden=\(observation.layerIsHidden)"
                + " source=\(observation.sourceSublayerName ?? "nil")"
                + " animations=\(animations)"
        }
        return [
            "== Variant 14 glassForeground Aberration probe ==",
            "context=panel-neither-standard size=480x200 cornerRadius=16 margin=40",
            "property=inputAberrationAmount requested=\(report.requestedValue)",
            observationLine("before", report.before),
            observationLine("immediate", report.immediate),
            observationLine("settled", report.settled),
            "objectReplaced=\(report.objectWasReplaced)",
        ].joined(separator: "\n")
    }

    private func runVibrantColorMatrixProbeSuite() {
        guard !isVibrantMatrixProbeRunning else { return }
        guard !state.hasActiveOverrides else {
            vibrantMatrixProbeStatus = "Disable Override before running the clean Recipe suite."
            return
        }

        let originalRenderer = state.rendererMode
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
        let originalMain = state.isTestWindowMain
        let originalPadding = state.windowPadding
        let originalVisibility = state.isTestWindowVisible

        vibrantMatrixProbeReports = []
        vibrantMatrixProbeStatus = "Preparing Variant 1 · Main Off…"
        isVibrantMatrixProbeRunning = true
        liveRefreshTask?.cancel()

        vibrantMatrixProbeTask = Task { @MainActor in
            defer {
                state.rendererMode = originalRenderer
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
                state.isTestWindowMain = originalMain
                state.windowPadding = originalPadding
                state.isTestWindowVisible = originalVisibility
                state.testWindow.sync(with: state)
                isVibrantMatrixProbeRunning = false
                vibrantMatrixProbeTask = nil
                scheduleLiveReadoutRefresh(refreshSchema: true)
            }

            state.rendererMode = .recipe
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
            state.windowPadding = 40
            state.isTestWindowVisible = true

            do {
                for variant in [1, 2] {
                    for requestedMain in [false, true] {
                        vibrantMatrixProbeStatus = "Settling Variant \(variant) · Main "
                            + (requestedMain ? "On…" : "Off…")
                        try await settleVibrantMatrixProbeContext(
                            variant: variant,
                            requestedMain: requestedMain
                        )

                        guard let glass = state.testWindow.liveGlass,
                              let capture = GlassLabTuning.captureLivePassAudit(from: glass)
                        else {
                            throw MatrixExportError.invalidMatrix(
                                "The controlled context produced no recursive pass snapshot."
                            )
                        }
                        let slots = vibrantColorMatrixPasses(in: capture.snapshot)
                        guard slots.count == 2 else {
                            throw MatrixExportError.invalidMatrix(
                                "Variant \(variant), Main \(requestedMain) exposed "
                                    + "\(slots.count) vibrantColorMatrix slots; expected 2."
                            )
                        }

                        for (index, pass) in slots.enumerated() {
                            let ordinal = index + 1
                            let slotID = "\(pass.layerPath)|\(pass.location)"
                            vibrantMatrixProbeStatus = "V\(variant) · Main "
                                + "\(requestedMain ? "On" : "Off") · Slot \(ordinal)/2 "
                                + "· Boolean vector…"
                            let booleanMutation = try await runVibrantMatrixMutationProbe(
                                .booleans,
                                selectedSlotID: slotID,
                                requestedMain: requestedMain
                            )

                            vibrantMatrixProbeStatus = "V\(variant) · Main "
                                + "\(requestedMain ? "On" : "Off") · Slot \(ordinal)/2 "
                                + "· Matrix coefficient…"
                            let matrixMutation = try await runVibrantMatrixMutationProbe(
                                .matrix,
                                selectedSlotID: slotID,
                                requestedMain: requestedMain
                            )

                            let report = VibrantMatrixCaseReport(
                                variant: variant,
                                requestedMain: requestedMain,
                                ordinal: ordinal,
                                booleanMutation: booleanMutation,
                                matrixMutation: matrixMutation
                            )
                            vibrantMatrixProbeReports.append(report)
                            state.reportOutput = "Validated \(vibrantMatrixProbeReports.count)/8 "
                                + "vibrantColorMatrix cases."
                        }
                    }
                }

                let passed = vibrantMatrixProbeReports.filter(\.accepted).count
                vibrantMatrixProbeStatus = "\(passed)/8 cases passed."
                state.reportOutput = vibrantMatrixProbeReportText(
                    vibrantMatrixProbeReports
                )
            } catch is CancellationError {
                vibrantMatrixProbeStatus = "Suite cancelled after "
                    + "\(vibrantMatrixProbeReports.count)/8 cases."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                vibrantMatrixProbeStatus = "Suite stopped: \(message)"
                state.reportOutput = vibrantMatrixProbeStatus ?? message
            }
        }
    }

    @MainActor
    private func settleVibrantMatrixProbeContext(
        variant: Int,
        requestedMain: Bool
    ) async throws {
        state.variant = variant
        state.isTestWindowMain = requestedMain
        for attempt in 1...4 {
            try await waitUntilApplicationIsActive(
                progress: "Matrix suite paused before V\(variant), Main "
                    + (requestedMain ? "On" : "Off")
            )
            state.testWindow.sync(with: state)
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            guard NSApp.isActive else { continue }
            if state.testWindow.isActuallyMain == requestedMain,
               !state.testWindow.isActuallyKey,
               state.testWindow.liveGlass != nil {
                return
            }
            if attempt < 4 {
                state.testWindow.sync(with: state)
            }
        }
        throw MatrixExportError.participationRejected(
            main: requestedMain,
            subdued: false,
            height: 200
        )
    }

    private func vibrantColorMatrixPasses(
        in snapshot: GlassLabTuning.PassAuditSnapshot
    ) -> [GlassLabTuning.PassAuditPassRecord] {
        snapshot.passes.values.filter {
            $0.name == "vibrantColorMatrix"
        }.sorted {
            [$0.layerPath, $0.location, $0.id].joined(separator: "|")
                < [$1.layerPath, $1.location, $1.id].joined(separator: "|")
        }
    }

    @MainActor
    private func runVibrantMatrixMutationProbe(
        _ kind: VibrantMatrixMutationKind,
        selectedSlotID: String,
        requestedMain: Bool
    ) async throws -> VibrantMatrixMutationReport {
        state.testWindow.rebuildGlass(with: state)
        try await Task.sleep(for: .milliseconds(350))
        try Task.checkCancellation()
        guard state.testWindow.isActuallyMain == requestedMain,
              !state.testWindow.isActuallyKey else {
            throw MatrixExportError.participationRejected(
                main: requestedMain,
                subdued: false,
                height: 200
            )
        }

        let beforePair = try captureVibrantMatrixProbePair(
            selectedSlotID: selectedSlotID
        )
        let applied: Bool
        switch kind {
        case .booleans:
            applied = GlassLabTuning.applyVibrantColorMatrixBooleanProbe(
                to: beforePair.glass,
                matching: beforePair.selectedPass
            )
        case .matrix:
            applied = GlassLabTuning.applyVibrantColorMatrixNudgeProbe(
                to: beforePair.glass,
                matching: beforePair.selectedPass
            )
        }
        guard applied else {
            throw MatrixExportError.invalidMatrix(
                "\(kind.rawValue) could not be written to \(selectedSlotID)."
            )
        }

        let immediatePair = try captureVibrantMatrixProbePair(
            selectedSlotID: selectedSlotID
        )
        try await Task.sleep(for: .milliseconds(350))
        try Task.checkCancellation()
        let settledPair = try captureVibrantMatrixProbePair(
            selectedSlotID: selectedSlotID
        )

        state.testWindow.rebuildGlass(with: state)
        try await Task.sleep(for: .milliseconds(350))
        try Task.checkCancellation()
        let resetPair = try captureVibrantMatrixProbePair(
            selectedSlotID: selectedSlotID
        )

        return VibrantMatrixMutationReport(
            kind: kind,
            before: beforePair.selected,
            immediate: immediatePair.selected,
            settled: settledPair.selected,
            peerBefore: beforePair.peer,
            peerSettled: settledPair.peer,
            reset: resetPair.selected,
            peerReset: resetPair.peer
        )
    }

    @MainActor
    private func captureVibrantMatrixProbePair(
        selectedSlotID: String
    ) throws -> (
        glass: NSGlassEffectView,
        selectedPass: GlassLabTuning.PassAuditPassRecord,
        selected: GlassLabTuning.VibrantColorMatrixProbeObservation,
        peer: GlassLabTuning.VibrantColorMatrixProbeObservation
    ) {
        guard let glass = state.testWindow.liveGlass,
              let capture = GlassLabTuning.captureLivePassAudit(from: glass) else {
            throw MatrixExportError.invalidMatrix(
                "The live matrix probe tree disappeared."
            )
        }
        let passes = vibrantColorMatrixPasses(in: capture.snapshot)
        guard passes.count == 2,
              let selectedPass = passes.first(where: {
                  "\($0.layerPath)|\($0.location)" == selectedSlotID
              }),
              let peerPass = passes.first(where: {
                  "\($0.layerPath)|\($0.location)" != selectedSlotID
              }),
              let selected = GlassLabTuning.captureVibrantColorMatrixProbe(
                  from: glass,
                  matching: selectedPass
              ),
              let peer = GlassLabTuning.captureVibrantColorMatrixProbe(
                  from: glass,
                  matching: peerPass
              ) else {
            throw MatrixExportError.invalidMatrix(
                "The exact selected/peer vibrantColorMatrix pair was not readable."
            )
        }
        return (glass, selectedPass, selected, peer)
    }

    private func vibrantMatrixProbeReportText(
        _ reports: [VibrantMatrixCaseReport]
    ) -> String {
        func mutationLine(_ report: VibrantMatrixMutationReport) -> String {
            let model = report.modelWriteAccepted ? "pass" : "FAIL"
            let presentation = report.presentationWriteAccepted ? "pass" : "FAIL"
            let peer = report.peerStayedIndependent ? "pass" : "FAIL"
            let reset = report.recipeResetAccepted ? "pass" : "FAIL"
            return "  \(report.kind.rawValue)"
                + " model=\(model)"
                + " presentation=\(presentation)"
                + " peerIndependent=\(peer)"
                + " reset=\(reset)"
                + " objectReplaced=\(report.objectWasReplaced)"
                + " animations=\(report.settled.animationKeyPaths.isEmpty ? "none" : report.settled.animationKeyPaths.joined(separator: ","))"
                + " matrix=\(report.before.modelMatrixFirstCoefficient)"
                + "→\(report.settled.modelMatrixFirstCoefficient)"
        }

        var lines = [
            "== Regular / Clear vibrantColorMatrix mutation suite ==",
            "context=Panel 480x200 cornerRadius=16 margin=40 subvariant=nil subdued=false",
            "cases=\(reports.filter(\.accepted).count)/\(reports.count) passed",
        ]
        for report in reports {
            lines.append(
                "V\(report.variant) Main=\(report.requestedMain) "
                    + "slot=\(report.ordinal) result=\(report.accepted ? "PASS" : "FAIL")"
            )
            lines.append(mutationLine(report.booleanMutation))
            lines.append(mutationLine(report.matrixMutation))
        }
        return lines.joined(separator: "\n")
    }

    private func passLayerReport(_ snapshot: GlassLabTuning.PassAuditSnapshot) -> String {
        snapshot.layers.keys.sorted().compactMap { key in
            guard let layer = snapshot.layers[key] else { return nil }
            return key
                + " · \(layer.layerClass)"
                + String(
                    format: " · frame=(%.1f,%.1f,%.1f×%.1f)",
                    layer.frame.x,
                    layer.frame.y,
                    layer.frame.width,
                    layer.frame.height
                )
                + String(format: " · opacity=%.4g", layer.opacity)
                + (layer.hasMask ? " · MASK" : "")
                + (layer.isHidden ? " · HIDDEN" : "")
                + (layer.masksToBounds ? " · CLIPS" : "")
        }.joined(separator: "\n")
    }

    private var selectedReadoutGlass: NSGlassEffectView? {
        state.testWindow.liveGlass
    }

    /// Renderer/host changes rebuild the test surface. Recipe Variant changes
    /// may replace a filter inventory, while Semantic Usage changes replace a
    /// SwiftUI-generated composition. Both must sync before their corresponding
    /// Inspector samples the live tree.
    private var recipeStructureTrigger: String {
        [
            state.rendererMode.rawValue,
            String(state.variant),
            state.subvariant,
            String(state.semanticUsage.rawValue),
            state.windowHostType.rawValue,
            String(state.isTestWindowVisible),
        ].joined(separator: "|")
    }

    /// A stable event token for every user-owned value that reshapes the live
    /// recipe context — size, recipe axes, window participation. SwiftUI
    /// observes the underlying @Observable properties; unlike a timer, this
    /// changes only in response to an actual lab action.
    private var liveReadoutTrigger: String {
        [
            String(state.glassWidth),
            String(state.glassHeight),
            String(state.cornerRadius),
            String(state.isSubdued),
            String(state.hasScrim),
            String(state.hasReducedTintOpacity),
            String(state.adaptiveAppearance),
            state.tintColor?.description ?? "nil",
            String(state.shaderOverridesEnabled),
            String(state.highlightOverridesEnabled),
            String(state.vibrantMatrixOverridesEnabled),
            String(state.isTestWindowMain),
            String(state.windowPadding),
            state.testAppearance.rawValue,
            state.testBackdrop.rawValue,
            String(state.isCapturingRecipeMatrix),
        ].joined(separator: "|")
    }

    /// Override value edits change only the captured payload, never the window
    /// context, so their event token stamps the live glass directly. Routing
    /// them through the full test-window sync replays window ordering and
    /// three deferred `_windowChangedKeyState` re-resolutions on every slider
    /// tick, which stalls Inspector drags.
    private var overridePayloadTrigger: String {
        [
            numericSignature(state.shaderOverrides),
            setSignature(state.shaderNilOverrides),
            colorSignature(state.shaderColorOverrides),
            pointSignature(state.shaderPointOverrides),
            numericSignature(state.layerGeometryOverrides),
            numericSignature(state.highlightOverrides),
            setSignature(state.highlightNilOverrides),
            colorSignature(state.highlightColorOverrides),
            vibrantMatrixSignature(state.vibrantMatrixOverrides),
        ].joined(separator: "|")
    }

    private var liveContextNotifications: Publishers.MergeMany<NotificationCenter.Publisher> {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didChangeScreenParametersNotification,
        ]
        return Publishers.MergeMany(names.map {
            NotificationCenter.default.publisher(for: $0)
        })
    }

    private func numericSignature(_ values: [String: Double]) -> String {
        values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    private func colorSignature(_ values: [String: NSColor]) -> String {
        values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.description)" }
            .joined(separator: ",")
    }

    private func pointSignature(_ values: [String: CGPoint]) -> String {
        values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.x),\($0.value.y)" }
            .joined(separator: ",")
    }

    private func setSignature(_ values: Set<String>) -> String {
        values.sorted().joined(separator: ",")
    }

    private func vibrantMatrixSignature(
        _ values: [String: GlassLabTuning.VibrantColorMatrixOverridePayload]
    ) -> String {
        values.keys.sorted().compactMap { slotID in
            guard let payload = values[slotID] else { return nil }
            let booleans = payload.booleanValues.keys.sorted().map {
                "\($0)=\(payload.booleanValues[$0]!.rawValue)"
            }.joined(separator: ",")
            let matrix = payload.matrixCoefficients.map { String($0) }
                .joined(separator: ",")
            return "\(slotID)|\(booleans)|\(matrix)"
        }.joined(separator: ";")
    }

    /// Recipe setters resolve through AppKit/WindowServer asynchronously.
    /// Debounce rapid slider events, then sample a short settling window; no
    /// task survives after the final 300 ms capture.
    private func scheduleLiveReadoutRefresh(refreshSchema: Bool = false) {
        liveRefreshTask?.cancel()
        hasPendingSchemaRefresh = state.rendererMode == .recipe
            && (hasPendingSchemaRefresh || refreshSchema)
        guard !state.isCapturingRecipeMatrix, !isCapturingSemanticTrees else { return }

        liveRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled,
                  !state.isCapturingRecipeMatrix,
                  !isCapturingSemanticTrees else { return }
            var stillNeedsSchema = hasPendingSchemaRefresh
            hasPendingSchemaRefresh = false
            if state.rendererMode == .recipe, stillNeedsSchema {
                stillNeedsSchema = !refreshInspectorSchemaIfAvailable()
            }
            restampOverridesIfNeeded()
            publishCurrentRendererSnapshot()

            for delay in [90, 180] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled,
                      !state.isCapturingRecipeMatrix,
                      !isCapturingSemanticTrees else { return }
                if state.rendererMode == .recipe, stillNeedsSchema {
                    stillNeedsSchema = !refreshInspectorSchemaIfAvailable()
                }
                restampOverridesIfNeeded()
                publishCurrentRendererSnapshot()
            }
        }
    }

    /// AppKit may install a freshly resolved filter/effect tree after a Recipe
    /// setter returns. The managed glass's layout hook and the window-context
    /// pipeline provide the deterministic lock; these settling-window writes
    /// are a final safety net for private replacements that expose neither
    /// lifecycle signal.
    private func restampOverridesIfNeeded() {
        guard state.hasActiveOverrides,
              let glass = selectedReadoutGlass else { return }
        GlassLabTuning.applyOverrides(from: state, to: glass)
    }

    /// Per-tick drag stamps bypass the observable override dictionaries: a
    /// dictionary write re-evaluates the whole Form and restamps the full
    /// captured payload. The row commits its final value to the dictionary
    /// once when the gesture ends.
    private func stampLiveShaderValue(_ value: Double, forKey key: String) {
        guard let glass = selectedReadoutGlass else { return }
        GlassLabTuning.applySingleShaderValue(value, forKey: key, to: glass)
    }

    private func stampLiveGeometryValue(_ value: Double, forKey key: String) {
        guard let glass = selectedReadoutGlass else { return }
        GlassLabTuning.applyLayerGeometry([key: value], to: glass)
    }

    private func stampLiveHighlightValue(_ value: Double, forKey key: String) {
        guard let glass = selectedReadoutGlass else { return }
        GlassLabTuning.applySingleHighlightValue(value, forKey: key, to: glass)
    }

    /// Metadata is effectively immutable for a filter inventory. Cache it
    /// until a structural trigger instead of issuing ~77 private
    /// attributesForKeyPath calls on every readout refresh.
    @discardableResult
    private func refreshInspectorSchemaIfAvailable() -> Bool {
        if inspectorShaderGroups.isEmpty {
            inspectorShaderGroups = GlassLabTuning.groupedShaderKnobs(from: nil)
        }
        if inspectorHighlightMetadata.isEmpty {
            inspectorHighlightMetadata = GlassLabTuning.captureHighlightAttributeMetadata()
        }
        guard let glass = selectedReadoutGlass else { return false }
        let metadata = GlassLabTuning.captureShaderAttributeMetadata(from: glass)
        guard !metadata.isEmpty else { return false }
        inspectorShaderMetadata = metadata
        inspectorShaderGroups = GlassLabTuning.groupedShaderKnobs(
            from: glass,
            metadata: metadata
        )
        return true
    }

    private func captureLiveReadoutSnapshot() -> LiveReadoutSnapshot? {
        guard let glass = selectedReadoutGlass else { return nil }
        return LiveReadoutSnapshot(
            shaderInputKeys: GlassLabTuning.captureShaderInputKeys(from: glass),
            shader: GlassLabTuning.captureShaderInputs(from: glass),
            shaderColors: GlassLabTuning.captureShaderColors(from: glass),
            shaderPoints: GlassLabTuning.captureShaderPoints(from: glass),
            shaderStrings: GlassLabTuning.captureShaderStrings(from: glass),
            highlightInputKeys: GlassLabTuning.captureHighlightInputKeys(from: glass),
            highlight: GlassLabTuning.captureHighlightValues(from: glass),
            highlightColors: GlassLabTuning.captureHighlightColors(from: glass),
            geometryKeys: GlassLabTuning.captureLayerGeometryKeys(from: glass),
            geometry: GlassLabTuning.captureLayerGeometry(from: glass)
        )
    }

    /// Settling reads can legitimately be identical. Avoid invalidating the
    /// large expanded Form unless a displayed value actually changed.
    private func publishLiveReadoutSnapshot() {
        let snapshot = captureLiveReadoutSnapshot()
        if snapshot != liveSnapshot {
            liveSnapshot = snapshot
        }
    }

    private func publishPassInventorySnapshot() {
        guard let glass = selectedReadoutGlass,
              let capture = GlassLabTuning.captureLivePassAudit(from: glass) else {
            if passInventorySnapshot != nil {
                passInventorySnapshot = nil
            }
            return
        }

        let currentIdentities = capture.objectIdentityBySlot
        var replacements = Set(replacedPassSlots.filter {
            currentIdentities[$0] != nil
        })
        for (slot, identity) in currentIdentities {
            if let previous = passObjectIdentityBySlot[slot], previous != identity {
                replacements.insert(slot)
            }
        }
        if currentIdentities != passObjectIdentityBySlot {
            passObjectIdentityBySlot = currentIdentities
        }
        if replacements != replacedPassSlots {
            replacedPassSlots = replacements
        }

        let snapshot = capture.snapshot
        let items = passInventoryItems(snapshot)
        let reconciledSelection = selectedPassItem(in: items)?.slotID
        if selectedPassSlotID != reconciledSelection {
            selectedPassSlotID = reconciledSelection
        }
        if snapshot != passInventorySnapshot {
            passInventorySnapshot = snapshot
        }
    }

    private func resetPassReplacementTracking() {
        if !passObjectIdentityBySlot.isEmpty {
            passObjectIdentityBySlot = [:]
        }
        if !replacedPassSlots.isEmpty {
            replacedPassSlots = []
        }
    }

    private func publishCurrentRendererSnapshot() {
        switch state.rendererMode {
        case .recipe:
            if semanticSnapshot != nil { semanticSnapshot = nil }
            publishLiveReadoutSnapshot()
            if selectedRecipePage == .passes {
                publishPassInventorySnapshot()
            } else if passInventorySnapshot != nil {
                passInventorySnapshot = nil
            }
        case .semanticUsage:
            if liveSnapshot != nil { liveSnapshot = nil }
            if passInventorySnapshot != nil { passInventorySnapshot = nil }
            resetPassReplacementTracking()
            let snapshot = GlassLabSemanticSnapshot.capture(
                from: state.testWindow.liveSemanticLayerRoot
            )
            if snapshot != semanticSnapshot {
                semanticSnapshot = snapshot
            }
        }
    }

    private func shaderMissingValueLabel(
        for key: String,
        in snapshot: LiveReadoutSnapshot?
    ) -> String {
        guard let snapshot else { return "—" }
        guard let inputKeys = snapshot.shaderInputKeys else { return "Pass Absent" }
        return inputKeys.contains(key) ? "nil" : "Absent"
    }

    private func highlightMissingValueLabel(
        for key: String,
        in snapshot: LiveReadoutSnapshot?
    ) -> String {
        guard let snapshot else { return "—" }
        guard let inputKeys = snapshot.highlightInputKeys else { return "Pass Absent" }
        return inputKeys.contains(key) ? "nil" : "Absent"
    }

    private func geometryMissingValueLabel(
        for key: String,
        in snapshot: LiveReadoutSnapshot?
    ) -> String {
        guard let snapshot else { return "—" }
        return snapshot.geometryKeys.contains(key) ? "nil" : "Absent"
    }

    private var readoutDescription: String {
        guard state.isTestWindowVisible else {
            return "The test window is hidden, so Recipe values cannot be read."
        }
        let actualMain = state.testWindow.isActuallyMain
        let actualKey = state.testWindow.isActuallyKey
        return "Showing current values from \(state.windowHostType.rawValue). "
            + "Main Window: \(state.isTestWindowMain ? "On" : "Off"); "
            + "actual main: \(actualMain), actual key: \(actualKey)."
    }

    private var semanticReadoutDescription: String {
        guard state.isTestWindowVisible else {
            return "The test window is hidden, so the Semantic layer tree cannot be read."
        }
        let status = state.testWindow.semanticRenderStatus
            ?? GlassLabSemanticRuntime.shared.status(for: state.semanticUsage)
        return "Showing \(state.semanticUsage.displayName) (SwiftUI role tag "
            + "\(state.semanticUsage.rawValue)) from \(state.windowHostType.rawValue). "
            + "Actual main: \(state.testWindow.isActuallyMain), "
            + "actual key: \(state.testWindow.isActuallyKey). \(status)."
    }

    private var appKitMaterializeProbeContextIsReady: Bool {
        state.rendererMode == .recipe
            && selectedRecipePage == .materialize
            && state.variant == appKitMaterializeVariant
            && (state.variant == 1 || state.variant == 2)
            && state.subvariant.isEmpty
            && !state.isSubdued
            && !state.hasScrim
            && !state.hasReducedTintOpacity
            && state.adaptiveAppearance == 2
            && !state.hasActiveOverrides
            && state.windowHostType == .panel
            && state.isTestWindowMain == appKitMaterializeRequestedMain
            && state.testWindow.isActuallyMain
                == appKitMaterializeRequestedMain
            && !state.testWindow.isActuallyKey
            && state.isTestWindowVisible
            && abs(state.glassWidth - 480) < 0.001
            && abs(state.glassHeight - 200) < 0.001
            && abs(state.cornerRadius - 16) < 0.001
            && abs(state.windowPadding - 40) < 0.001
            && (
                state.tintColor == nil
                    || state.testWindow.liveGlass.map {
                        GlassLabTuning.hasTintColorMatrix(on: $0)
                    } == true
            )
    }

    private var appKitMaterializeProgressBinding: Binding<Double> {
        Binding {
            appKitMaterializeProgress
        } set: { value in
            setAppKitMaterializeProgress(value)
        }
    }

    private var appKitMaterializeViewEnvelopeBinding: Binding<Bool> {
        Binding {
            appKitMaterializeIncludesViewEnvelope
        } set: { enabled in
            appKitMaterializeIncludesViewEnvelope = enabled
            applyAppKitMaterializeProgress()
        }
    }

    private var appKitMaterializeTintBinding: Binding<Color> {
        Binding {
            state.tintColor.map(Color.init) ?? Color.black.opacity(0)
        } set: { color in
            let nsColor = NSColor(color)
            setAppKitMaterializeTint(
                nsColor.alphaComponent > 0 ? nsColor : nil
            )
        }
    }

    private func setAppKitMaterializeTint(_ color: NSColor?) {
        state.tintColor = color
        requestAppKitMaterializeProbeContext()
    }

    private func requestAppKitMaterializeProbeContext() {
        cancelAppKitMaterializeProbe(rebuild: true)
        isAnimatingAppKitMaterialize = true
        if state.hasActiveOverrides {
            overridesEnabledBinding.wrappedValue = false
        }

        state.rendererMode = .recipe
        state.variant = appKitMaterializeVariant
        state.subvariant = ""
        state.isSubdued = false
        state.hasScrim = false
        state.hasReducedTintOpacity = false
        state.adaptiveAppearance = 2
        state.glassWidth = 480
        state.glassHeight = 200
        state.cornerRadius = 16
        state.windowPadding = 40
        state.windowHostType = .panel
        state.isTestWindowVisible = true
        state.isTestWindowMain = appKitMaterializeRequestedMain
        appKitMaterializeProgress = 1
        appKitMaterializeStatus =
            "Preparing the stable NSGlass Main "
            + (appKitMaterializeRequestedMain ? "On" : "Off")
            + " endpoint…"
        state.testWindow.sync(with: state)

        appKitMaterializeTask = Task { @MainActor in
            do {
                guard try await waitForAppKitMaterializeProbeContext() else {
                    appKitMaterializeStatus =
                        "The fixed NSGlass context did not settle truthfully."
                    isAnimatingAppKitMaterialize = false
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                appKitMaterializeStatus =
                    "The fixed NSGlass context did not settle truthfully."
                isAnimatingAppKitMaterialize = false
                return
            }
            applyAppKitMaterializeProgress()
            isAnimatingAppKitMaterialize = false
        }
    }

    private func waitForAppKitMaterializeProbeContext() async throws -> Bool {
        var activeAttempts = 0
        while activeAttempts < 24 {
            try Task.checkCancellation()
            if appKitMaterializeProbeContextIsReady {
                return true
            }
            guard NSApp.isActive else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            if activeAttempts > 0, activeAttempts.isMultiple(of: 4) {
                state.testWindow.sync(with: state)
            }
            activeAttempts += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        return appKitMaterializeProbeContextIsReady
    }

    private func setAppKitMaterializeProgress(_ progress: Double) {
        appKitMaterializeProgress = min(max(progress, 0), 1)
        applyAppKitMaterializeProgress()
    }

    private func applyAppKitMaterializeProgress(
        publishesResult: Bool = true
    ) {
        guard appKitMaterializeProbeContextIsReady else {
            if publishesResult {
                appKitMaterializeStatus =
                    "The fixed Regular/Clear NSGlass context is still settling."
            }
            return
        }
        guard let result =
            state.testWindow.applyAppKitMaterializeBackgroundProbe(
                progress: appKitMaterializeProgress,
                variant: appKitMaterializeVariant,
                requestedMain: appKitMaterializeRequestedMain,
                tintColor: state.tintColor,
                includesViewEnvelope: appKitMaterializeIncludesViewEnvelope
            ) else {
            if publishesResult {
                appKitMaterializeResult = nil
                appKitMaterializeStatus =
                    "The live NSGlass tree has no glassBackground pass."
            }
            return
        }
        guard publishesResult else { return }
        appKitMaterializeResult = result
        if result.isAccepted {
            let tintSuffix: String
            if result.requestedTintAlpha != nil {
                tintSuffix = result.tintMatrixMatched
                    ? " and Tint matrix alpha."
                    : " with a Tint matrix mismatch."
            } else {
                tintSuffix = ""
            }
            appKitMaterializeStatus =
                "Applied and read back \(result.acceptedKeyCount)/"
                + "\(result.requestedKeys.count) background fields"
                + (result.requestedMain
                    ? " and \(result.acceptedRimKeyCount)/"
                        + "\(result.requestedRimKeys.count) Rim gate"
                    : "")
                + tintSuffix
                + (tintSuffix.isEmpty ? "." : "")
        } else {
            appKitMaterializeStatus =
                "Applied \(result.acceptedKeyCount)/\(result.requestedKeys.count); "
                + "\(result.mismatchedKeys.count) background and "
                + "\(result.mismatchedRimKeys.count) Rim readback mismatches"
                + (result.requestedTintAlpha != nil
                    ? "; Tint matrix "
                        + (result.tintMatrixFound ? "mismatched." : "missing.")
                    : ".")
        }
        publishLiveReadoutSnapshot()
    }

    private func animateAppKitMaterialize(to target: Double) {
        guard appKitMaterializeProbeContextIsReady else {
            appKitMaterializeStatus =
                "The fixed Regular/Clear NSGlass context is still settling."
            return
        }
        appKitMaterializeTask?.cancel()
        let start = appKitMaterializeProgress
        let destination = min(max(target, 0), 1)
        guard abs(destination - start) > 0.0001 else {
            applyAppKitMaterializeProgress()
            return
        }

        isAnimatingAppKitMaterialize = true
        appKitMaterializeStatus =
            destination > start ? "Replaying Linear In…" : "Replaying Linear Out…"
        appKitMaterializeTask = Task { @MainActor in
            let frameCount = 240
            for frame in 1...frameCount {
                guard !Task.isCancelled else {
                    isAnimatingAppKitMaterialize = false
                    return
                }
                let progress = Double(frame) / Double(frameCount)
                appKitMaterializeProgress =
                    start + (destination - start) * progress
                applyAppKitMaterializeProgress(publishesResult: false)
                if frame < frameCount {
                    try? await Task.sleep(for: .nanoseconds(16_666_667))
                }
            }
            applyAppKitMaterializeProgress()
            isAnimatingAppKitMaterialize = false
        }
    }

    private func cancelAppKitMaterializeProbe(rebuild: Bool) {
        let hadProbe = appKitMaterializeResult != nil
            || abs(appKitMaterializeProgress - 1) > 0.0001
            || isAnimatingAppKitMaterialize
        appKitMaterializeTask?.cancel()
        appKitMaterializeTask = nil
        isAnimatingAppKitMaterialize = false
        state.testWindow.clearAppKitMaterializeBackgroundProbe(
            rebuild: rebuild && hadProbe
        )
        appKitMaterializeProgress = 1
        appKitMaterializeResult = nil
        appKitMaterializeStatus = nil
    }

    private var materializeProbeContextIsReady: Bool {
        state.rendererMode == .semanticUsage
            && selectedSemanticPage == .transition
            && (state.semanticUsage == .regular || state.semanticUsage == .clear)
            && state.windowHostType == .panel
            && state.isTestWindowMain == materializeRequestedMain
            && state.testWindow.isActuallyMain == materializeRequestedMain
            && !state.testWindow.isActuallyKey
            && state.testAppearance == materializeRequestedAppearance
            && materializeRequestedAppearance.matchesName(
                state.testWindow.effectiveAppearanceName ?? ""
            )
            && state.testBackdrop == materializeRequestedBackdrop
            && state.isTestWindowVisible
            && abs(state.glassWidth - materializeRequestedSize.width) < 0.001
            && abs(state.glassHeight - materializeRequestedSize.height) < 0.001
            && abs(state.cornerRadius - 16) < 0.001
            && abs(state.windowPadding - 40) < 0.001
    }

    private func configureSemanticTransitionProbe() {
        let enabled = state.rendererMode == .semanticUsage
            && selectedSemanticPage == .transition
            && state.isTestWindowVisible

        if enabled,
           state.semanticUsage != .regular,
           state.semanticUsage != .clear {
            state.semanticUsage = .regular
            state.testWindow.sync(with: state)
        }
        if !enabled {
            materializePresented = true
        }
        state.testWindow.configureSemanticTransitionProbe(
            enabled: enabled,
            presented: materializePresented
        )
    }

    private func requestMaterializeCaptureContext(
        usage: GlassLabSemanticUsage,
        requestedMain: Bool,
        tintColor: NSColor?,
        appearance: GlassLabTestAppearance,
        backdrop: GlassLabBackdropMode,
        glassSize: CGSize = CGSize(width: 480, height: 200)
    ) {
        materializeRequestedSize = glassSize
        state.rendererMode = .semanticUsage
        state.semanticUsage = usage
        state.tintColor = tintColor
        state.glassWidth = glassSize.width
        state.glassHeight = glassSize.height
        state.cornerRadius = 16
        state.windowHostType = .panel
        state.testAppearance = appearance
        state.testBackdrop = backdrop
        state.isTestWindowMain = requestedMain
        state.windowPadding = 40
        state.isTestWindowVisible = true
        materializePresented = true
        state.testWindow.sync(with: state)
        configureSemanticTransitionProbe()
        scheduleLiveReadoutRefresh(refreshSchema: true)
    }

    private func waitForMaterializeCaptureContext() async throws -> Bool {
        for attempt in 0..<24 {
            try Task.checkCancellation()
            try await waitUntilApplicationIsActive(
                progress: "Materialize capture paused while the app is inactive."
            )
            if materializeProbeContextIsReady {
                return true
            }
            if attempt > 0, attempt.isMultiple(of: 4) {
                state.testWindow.sync(with: state)
                configureSemanticTransitionProbe()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return materializeProbeContextIsReady
    }

    private func runManualMaterializeTransition(
        _ direction: GlassLabMaterializeDirection
    ) {
        guard state.rendererMode == .semanticUsage,
              selectedSemanticPage == .transition else {
            materializeCaptureStatus = "Open the SwiftUI Transition page first."
            return
        }
        let target = direction.targetPresentedState
        materializePresented = target
        state.testWindow.setSemanticTransitionPresented(
            target,
            animationMode: materializeAnimationMode,
            linearDuration: materializeLinearDuration
        )
        materializeCaptureStatus = "\(direction.rawValue) triggered with \(materializeAnimationMode.rawValue)."
    }

    private func cancelMaterializeCapture() {
        materializeCaptureTask?.cancel()
        materializeCaptureTask = nil
        isCapturingMaterialize = false
    }

    private func captureMaterializeTransition(
        _ direction: GlassLabMaterializeDirection
    ) {
        guard state.rendererMode == .semanticUsage,
              selectedSemanticPage == .transition else {
            materializeCaptureStatus =
                "Open the SwiftUI Transition page before capturing."
            return
        }
        guard !isCapturingMaterialize else { return }

        cancelMaterializeCapture()
        isCapturingMaterialize = true
        materializeCapture = nil
        let usage: GlassLabSemanticUsage =
            state.semanticUsage == .clear ? .clear : .regular
        let requestedMain = materializeRequestedMain
        let animationMode = materializeAnimationMode
        let linearDuration = materializeLinearDuration
        materializeCaptureStatus =
            "Preparing Panel · Main "
            + (requestedMain ? "On" : "Off")
            + " · 480×200 capture context…"
        let tintColor = state.tintColor
        let tint = GlassLabTintDescriptor(
            label: tintColor == nil ? "None" : "Custom",
            color: tintColor,
            reducedTintOpacity: false
        )

        materializeCaptureTask = Task { @MainActor in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .userInitiated,
                    .idleSystemSleepDisabled,
                    .idleDisplaySleepDisabled,
                ],
                reason: "Capturing SwiftUI Materialize Transition"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                isCapturingMaterialize = false
                materializeCaptureTask = nil
            }

            do {
                let capture = try await performMaterializeCapture(
                    usage: usage,
                    direction: direction,
                    animationMode: animationMode,
                    linearDuration: linearDuration,
                    requestedMain: requestedMain,
                    tint: tint,
                    tintColor: tintColor,
                    appearance: materializeRequestedAppearance,
                    backdrop: materializeRequestedBackdrop
                )
                materializeCapture = capture
                state.reportOutput = capture.report
                let presentationStates = Set(capture.samples.compactMap {
                    $0.snapshot.presentation?.report
                }).count
                let maximumAnimations = capture.samples.map {
                    $0.snapshot.animations.count
                }.max() ?? 0
                materializeCaptureStatus = "Captured \(capture.samples.count) samples · "
                    + "\(presentationStates) presentation states · "
                    + "up to \(maximumAnimations) attached animations."
            } catch is CancellationError {
                materializeCaptureStatus = "Materialize capture cancelled."
            } catch {
                materializeCaptureStatus = "Materialize capture failed: \(error.localizedDescription)"
            }
        }
    }

    private func captureFullMaterializeStudy() {
        guard !isCapturingMaterializeStudy else { return }
        guard state.rendererMode == .semanticUsage,
              selectedSemanticPage == .transition else {
            materializeStudyStatus =
                "Open the SwiftUI Transition page before capturing."
            return
        }

        cancelMaterializeCapture()
        materializeStudyDocument = nil
        materializeStudyStatus = "Preparing full P1 coverage context…"
        isCapturingMaterializeStudy = true

        let originalRenderer = state.rendererMode
        let originalSemanticPage = selectedSemanticPage
        let originalUsage = state.semanticUsage
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
        let originalRequestedMain = materializeRequestedMain
        let originalRequestedAppearance = materializeRequestedAppearance
        let originalRequestedBackdrop = materializeRequestedBackdrop
        let originalAnimationMode = materializeAnimationMode
        let originalDuration = materializeLinearDuration
        let originalPresented = materializePresented

        materializeStudyTask = Task { @MainActor in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .userInitiated,
                    .idleSystemSleepDisabled,
                    .idleDisplaySleepDisabled,
                ],
                reason: "Capturing Full P1 Liquid Glass Materialize Matrix"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                state.rendererMode = originalRenderer
                selectedSemanticPage = originalSemanticPage
                state.semanticUsage = originalUsage
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
                materializeRequestedMain = originalRequestedMain
                materializeRequestedAppearance = originalRequestedAppearance
                materializeRequestedBackdrop = originalRequestedBackdrop
                materializeAnimationMode = originalAnimationMode
                materializeLinearDuration = originalDuration
                materializePresented = originalPresented
                state.testWindow.sync(with: state)
                configureSemanticTransitionProbe()
                isCapturingMaterializeStudy = false
                materializeStudyTask = nil
                scheduleLiveReadoutRefresh(refreshSchema: true)
            }

            do {
                state.rendererMode = .semanticUsage
                selectedSemanticPage = .transition
                materializeAnimationMode = .linear
                materializeLinearDuration = 1
                configureSemanticTransitionProbe()

                let materials: [GlassLabSemanticUsage] = [.regular, .clear]
                let tintPresets: [GlassLabTintPreset] = [.none, .coral50]
                let expectedCount = materials.count
                    * 2
                    * GlassLabTestAppearance.controlledCases.count
                    * GlassLabBackdropMode.controlledCases.count
                    * tintPresets.count
                    * GlassLabMaterializeDirection.allCases.count
                var transitions: [GlassLabMaterializeCapture] = []
                transitions.reserveCapacity(expectedCount)

                for appearance in GlassLabTestAppearance.controlledCases {
                    for backdrop in GlassLabBackdropMode.controlledCases {
                        for requestedMain in [false, true] {
                            for usage in materials {
                                for tintPreset in tintPresets {
                                    for direction in
                                        GlassLabMaterializeDirection.allCases {
                                        let ordinal = transitions.count + 1
                                        materializeStudyStatus =
                                            "P1 \(ordinal)/\(expectedCount) · "
                                            + "\(usage.displayName) · Main "
                                            + (requestedMain ? "On" : "Off")
                                            + " · \(appearance.rawValue)"
                                            + " · \(backdrop.rawValue) backdrop"
                                            + " · \(tintPreset.displayName)"
                                            + " · \(direction.rawValue)"
                                        transitions.append(
                                            try await performMaterializeCapture(
                                                usage: usage,
                                                direction: direction,
                                                animationMode: .linear,
                                                linearDuration: 1,
                                                requestedMain: requestedMain,
                                                tint: tintPreset.descriptor,
                                                tintColor: tintPreset.color,
                                                appearance: appearance,
                                                backdrop: backdrop
                                            )
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                guard transitions.count == expectedCount else {
                    throw TintStudyError.invalidMaterializeStudy(
                        expected: expectedCount,
                        actual: transitions.count
                    )
                }
                guard transitions.allSatisfy({
                    $0.samples.count == 9
                        && $0.context.actualMain == $0.context.requestedMain
                        && !$0.context.actualKey
                        && $0.context.requestedAppearance.matchesName(
                            $0.context.effectiveAppearance
                        )
                        && GlassLabBackdropMode.controlledCases.contains(
                            $0.context.backdrop
                        )
                }) else {
                    throw TintStudyError.transitionContextChanged
                }

                let document = GlassLabMaterializeStudyDocument(
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
                        animationMode: .linear,
                        animationDuration: 1,
                        materials: materials.map(\.displayName),
                        participation: ["Main Off", "Main On"],
                        appearances:
                            GlassLabTestAppearance.controlledCases,
                        backdrops: GlassLabBackdropMode.controlledCases,
                        tints: tintPresets.map(\.displayName),
                        directions:
                            GlassLabMaterializeDirection.allCases
                    ),
                    transitions: transitions
                )
                materializeStudyDocument = document
                state.reportOutput = document.report
                let sampleCount = transitions.reduce(0) {
                    $0 + $1.samples.count
                }
                materializeStudyStatus =
                    "Complete · \(transitions.count) transitions / "
                    + "\(sampleCount) samples."
            } catch is CancellationError {
                materializeStudyStatus =
                    "P1 Materialize matrix cancelled; partial data discarded."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                materializeStudyStatus =
                    "P1 Materialize matrix failed: \(message)"
                state.reportOutput = materializeStudyStatus ?? message
            }
        }
    }

    /// Unattended entry point for the geometry spot check, so the sweep can run
    /// from a script instead of a save panel:
    ///
    ///     LiquidGlassLab.app/Contents/MacOS/LiquidGlassLab \
    ///       --capture-size-study /path/to/output.json
    ///
    /// The app still needs a real session and foreground activation because
    /// Main-On participation is a genuine AppKit window state; this only
    /// removes the manual button press and the save panel.
    @MainActor
    private func runHeadlessCaptureIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--capture-size-study"),
              arguments.index(after: flagIndex) < arguments.endIndex else {
            return
        }
        let destination = URL(
            fileURLWithPath: arguments[arguments.index(after: flagIndex)]
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Let the scene, the test window, and the first Recipe resolution
        // settle before the first participation request.
        try? await Task.sleep(for: .seconds(2))

        var exitCode: Int32 = 0
        do {
            let document = try await performMaterializeSizeStudy()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload = try encoder.encode(document)
            // The app is sandboxed, so an arbitrary destination usually needs a
            // save panel. Fall back to the container's temporary directory and
            // report where the capture actually landed.
            var written = destination
            do {
                try payload.write(to: destination, options: .atomic)
            } catch {
                written = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent(destination.lastPathComponent)
                try payload.write(to: written, options: .atomic)
            }
            FileHandle.standardError.write(Data(
                (document.report + "\nWrote \(written.path)\n").utf8
            ))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            FileHandle.standardError.write(Data(
                "Size study failed: \(message)\n".utf8
            ))
            exitCode = 1
        }
        state.testWindow.tearDown()
        exit(exitCode)
    }

    /// Sweeps `shortSide` while holding every closed axis fixed. 48 sits below
    /// both refraction caps, 200 reproduces the accepted baseline geometry, and
    /// 400 sits above them, so a cap-crossing shape change cannot hide.
    ///
    /// Window padding stays at the baseline 40 rather than tracking
    /// `0.35 · shortSide`. That under-insets the largest surface visually, but
    /// this study only reads model values, which the window frame does not
    /// affect, and holding it fixed keeps the 200 rows comparable with the
    /// 64-run matrix.
    @MainActor
    private func performMaterializeSizeStudy() async throws
        -> GlassLabMaterializeSizeStudyDocument
    {
        let shortSides: [Double] = [48, 200, 400]
        let glassWidth: Double = 480
        let materials: [GlassLabSemanticUsage] = [.regular, .clear]
        let appearance = GlassLabTestAppearance.light
        let backdrop = GlassLabBackdropMode.light
        let direction = GlassLabMaterializeDirection.insertion
        let tintPreset = GlassLabTintPreset.none

        state.rendererMode = .semanticUsage
        selectedSemanticPage = .transition
        materializeAnimationMode = .linear
        materializeLinearDuration = 1
        configureSemanticTransitionProbe()

        let expectedCount = shortSides.count * materials.count * 2
        var transitions: [GlassLabMaterializeCapture] = []
        transitions.reserveCapacity(expectedCount)

        for shortSide in shortSides {
            for usage in materials {
                for requestedMain in [false, true] {
                    materializeStudyStatus =
                        "Size \(transitions.count + 1)/\(expectedCount) · "
                        + "shortSide \(Int(shortSide)) · \(usage.displayName)"
                        + " · Main \(requestedMain ? "On" : "Off")"
                    transitions.append(
                        try await performMaterializeCapture(
                            usage: usage,
                            direction: direction,
                            animationMode: .linear,
                            linearDuration: 1,
                            requestedMain: requestedMain,
                            tint: tintPreset.descriptor,
                            tintColor: tintPreset.color,
                            appearance: appearance,
                            backdrop: backdrop,
                            glassSize: CGSize(
                                width: glassWidth,
                                height: shortSide
                            )
                        )
                    )
                }
            }
        }

        guard transitions.count == expectedCount else {
            throw TintStudyError.invalidMaterializeStudy(
                expected: expectedCount,
                actual: transitions.count
            )
        }
        guard transitions.allSatisfy({
            $0.context.actualMain == $0.context.requestedMain
                && !$0.context.actualKey
        }) else {
            throw TintStudyError.transitionContextChanged
        }

        return GlassLabMaterializeSizeStudyDocument(
            formatVersion: 1,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            operatingSystem:
                ProcessInfo.processInfo.operatingSystemVersionString,
            context: .init(
                hostType: GlassLabWindowHostType.panel.rawValue,
                glassWidth: glassWidth,
                shortSides: shortSides,
                cornerRadius: 16,
                windowMargin: 40,
                animationMode: .linear,
                animationDuration: 1,
                materials: materials.map(\.displayName),
                participation: ["Main Off", "Main On"],
                appearance: appearance,
                backdrop: backdrop,
                direction: direction
            ),
            transitions: transitions
        )
    }

    private func exportMaterializeStudy() {
        guard let document = materializeStudyDocument else {
            materializeStudyStatus =
                "Capture the full P1 Materialize matrix before exporting."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "glass-materialize-p1-matrix.json"
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(
                to: destinationURL,
                options: .atomic
            )
            materializeStudyStatus =
                "Exported \(document.transitions.count) transitions to "
                + destinationURL.path
        } catch {
            materializeStudyStatus =
                "P1 Materialize export failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func performMaterializeCapture(
        usage: GlassLabSemanticUsage,
        direction: GlassLabMaterializeDirection,
        animationMode: GlassLabMaterializeAnimationMode,
        linearDuration: Double,
        requestedMain: Bool,
        tint: GlassLabTintDescriptor,
        tintColor: NSColor?,
        appearance: GlassLabTestAppearance,
        backdrop: GlassLabBackdropMode,
        glassSize: CGSize = CGSize(width: 480, height: 200)
    ) async throws -> GlassLabMaterializeCapture {
        materializeRequestedMain = requestedMain
        materializeRequestedAppearance = appearance
        materializeRequestedBackdrop = backdrop
        requestMaterializeCaptureContext(
            usage: usage,
            requestedMain: requestedMain,
            tintColor: tintColor,
            appearance: appearance,
            backdrop: backdrop,
            glassSize: glassSize
        )
        guard try await waitForMaterializeCaptureContext() else {
            throw TintStudyError.contextRejected(
                "Panel · Main \(requestedMain ? "On" : "Off") · Key Off"
            )
        }

        materializeCaptureStatus =
            "Settling \(direction.rawValue.lowercased()) start endpoint…"
        let initialPresented = direction.initialPresentedState
        materializePresented = initialPresented
        state.testWindow.configureSemanticTransitionProbe(
            enabled: true,
            presented: initialPresented
        )
        try await Task.sleep(for: .milliseconds(240))
        try Task.checkCancellation()
        try await requireMaterializeContext()

        guard let preflight = captureCurrentMaterializeSnapshot() else {
            throw TintStudyError.missingSemanticSnapshot
        }
        var samples = [
            GlassLabMaterializeSample(
                phase: "preflight",
                requestedProgress: 0,
                elapsed: 0,
                snapshot: preflight
            ),
        ]

        materializeCaptureStatus =
            "Triggered \(direction.rawValue.lowercased()); discovering attached animations…"
        let start = Date()
        let targetPresented = direction.targetPresentedState
        materializePresented = targetPresented
        state.testWindow.setSemanticTransitionPresented(
            targetPresented,
            animationMode: animationMode,
            linearDuration: linearDuration
        )
        await Task.yield()
        try await Task.sleep(for: .milliseconds(16))
        try Task.checkCancellation()
        try await requireMaterializeContext()

        guard let trigger = captureCurrentMaterializeSnapshot() else {
            throw TintStudyError.missingSemanticSnapshot
        }
        samples.append(
            GlassLabMaterializeSample(
                phase: "trigger",
                requestedProgress: 0,
                elapsed: Date().timeIntervalSince(start),
                snapshot: trigger
            )
        )

        let triggerDuration = candidateMaterializeDuration(in: trigger)
        let samplingDuration: Double
        switch animationMode {
        case .linear:
            samplingDuration = linearDuration
        case .systemDefault:
            // A CA animation inventory is preferred. The fallback only
            // controls observation timestamps and is never reported as an
            // observed system duration.
            samplingDuration = triggerDuration > 0 ? triggerDuration : 0.8
        }

        for progress in [0.125, 0.25, 0.5, 0.75, 0.875, 1.0] {
            let targetElapsed = samplingDuration * progress
            let remaining = targetElapsed - Date().timeIntervalSince(start)
            if remaining > 0 {
                try await Task.sleep(for: .seconds(remaining))
            }
            try Task.checkCancellation()
            materializeCaptureStatus = "Sampling \(Int(progress * 100))%…"
            try await requireMaterializeContext()
            guard let snapshot = captureCurrentMaterializeSnapshot() else {
                throw TintStudyError.missingSemanticSnapshot
            }
            samples.append(
                GlassLabMaterializeSample(
                    phase: progress == 1 ? "endpoint" : "sample",
                    requestedProgress: progress,
                    elapsed: Date().timeIntervalSince(start),
                    snapshot: snapshot
                )
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        try Task.checkCancellation()
        try await requireMaterializeContext()
        guard let settled = captureCurrentMaterializeSnapshot() else {
            throw TintStudyError.missingSemanticSnapshot
        }
        samples.append(
            GlassLabMaterializeSample(
                phase: "settled",
                requestedProgress: 1,
                elapsed: Date().timeIntervalSince(start),
                snapshot: settled
            )
        )

        let maximumAttachedAnimationDuration = samples
            .map { candidateMaterializeDuration(in: $0.snapshot) }
            .max() ?? 0
        let context = GlassLabMaterializeCaptureContext(
            hostType: state.windowHostType.rawValue,
            requestedMain: requestedMain,
            actualMain: state.testWindow.isActuallyMain,
            actualKey: state.testWindow.isActuallyKey,
            requestedAppearance: appearance,
            effectiveAppearance:
                state.testWindow.effectiveAppearanceName ?? "unknown",
            backdrop: backdrop,
            glassWidth: state.glassWidth,
            glassHeight: state.glassHeight,
            cornerRadius: state.cornerRadius,
            windowMargin: state.windowPadding,
            tint: tint
        )
        return GlassLabMaterializeCapture(
            formatVersion: 3,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            roleTag: usage.rawValue,
            usage: usage.displayName,
            direction: direction,
            animationMode: animationMode,
            requestedDuration: animationMode == .linear
                ? linearDuration
                : nil,
            maximumAttachedAnimationDuration:
                maximumAttachedAnimationDuration,
            samplingDuration: samplingDuration,
            context: context,
            samples: samples
        )
    }

    @MainActor
    private func requireMaterializeContext() async throws {
        try await waitUntilApplicationIsActive(
            progress: "Materialize capture paused while the app is inactive."
        )
        if !materializeProbeContextIsReady {
            state.testWindow.sync(with: state)
            configureSemanticTransitionProbe()
            try await Task.sleep(for: .milliseconds(120))
        }
        guard materializeProbeContextIsReady else {
            throw TintStudyError.transitionContextChanged
        }
    }

    @MainActor
    private func captureCurrentMaterializeSnapshot()
        -> GlassLabSemanticTransitionSnapshot? {
        state.testWindow.liveWindow?.contentView?.layoutSubtreeIfNeeded()
        state.testWindow.liveWindow?.contentView?.displayIfNeeded()
        return GlassLabSemanticTransitionSnapshot.capture(
            from: state.testWindow.liveSemanticLayerRoot
        )
    }

    private func candidateMaterializeDuration(
        in snapshot: GlassLabSemanticTransitionSnapshot
    ) -> Double {
        snapshot.animations
            .filter {
                $0.repeatCount == 0
                    && $0.duration > 0
                    && $0.duration <= 8
            }
            .map(\.duration)
            .max() ?? 0
    }

    private func copyMaterializeCaptureReport() {
        guard let capture = materializeCapture else { return }
        state.reportOutput = capture.report
        copyToPasteboard(capture.report)
    }

    private func exportMaterializeCapture() {
        guard let capture = materializeCapture else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let mode = capture.animationMode == .linear ? "linear" : "default"
        panel.nameFieldStringValue = "materialize-"
            + capture.usage.lowercased()
            + "-\(capture.direction.rawValue.lowercased())"
            + "-\(mode).json"
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(capture).write(
                to: destinationURL,
                options: .atomic
            )
            materializeCaptureStatus = "Exported capture to \(destinationURL.path)"
        } catch {
            materializeCaptureStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private var tintBinding: Binding<Color> {
        Binding {
            state.tintColor.map(Color.init) ?? Color.black.opacity(0)
        } set: { color in
            let nsColor = NSColor(color)
            state.tintColor = nsColor.alphaComponent > 0 ? nsColor : nil
        }
    }

    /// The lab keeps three internal override channels (Glass Filter, Rim, and
    /// exact-slot Color Matrix); this single user-facing switch drives all of
    /// them through one capture/reset lifecycle.
    private var overridesEnabledBinding: Binding<Bool> {
        Binding {
            state.hasActiveOverrides
        } set: { enabled in
            let currentlyEnabled = state.hasActiveOverrides
            guard enabled != currentlyEnabled else { return }
            if enabled {
                _ = refreshInspectorSchemaIfAvailable()
                let matrixPayload = selectedReadoutGlass.map {
                    GlassLabTuning.captureVibrantColorMatrixOverrides(from: $0)
                } ?? [:]
                guard let snapshot = captureLiveReadoutSnapshot(),
                      snapshot.shaderInputKeys != nil
                          || snapshot.highlightInputKeys != nil
                          || !matrixPayload.isEmpty else {
                    state.reportOutput = "The current Variant has no accepted pass payload to override."
                    return
                }
                if snapshot.shaderInputKeys != nil {
                    shaderOverrideBaseline = snapshot
                    installShaderOverrides(from: snapshot)
                }
                if snapshot.highlightInputKeys != nil {
                    highlightOverrideBaseline = snapshot
                    installHighlightOverrides(from: snapshot)
                }
                if !matrixPayload.isEmpty {
                    vibrantMatrixOverrideBaseline = matrixPayload
                    installVibrantMatrixOverrides(matrixPayload)
                }
            } else {
                state.shaderOverridesEnabled = false
                state.highlightOverridesEnabled = false
                state.vibrantMatrixOverridesEnabled = false
                shaderOverrideBaseline = nil
                highlightOverrideBaseline = nil
                vibrantMatrixOverrideBaseline = nil
                clearShaderOverridePayload()
                clearHighlightOverridePayload()
                clearVibrantMatrixOverridePayload()
                rebuildAllGlassSurfaces()
            }
        }
    }

    private func resetAllOverrides() {
        if let shaderOverrideBaseline {
            installShaderOverrides(from: shaderOverrideBaseline)
        }
        if let highlightOverrideBaseline {
            installHighlightOverrides(from: highlightOverrideBaseline)
        }
        if let vibrantMatrixOverrideBaseline {
            installVibrantMatrixOverrides(vibrantMatrixOverrideBaseline)
        }
        state.testWindow.sync(with: state)
        scheduleLiveReadoutRefresh()
    }

    private func installShaderOverrides(from snapshot: LiveReadoutSnapshot) {
        state.shaderOverrides = snapshot.shader
        state.shaderColorOverrides = snapshot.shaderColors
        state.shaderPointOverrides = snapshot.shaderPoints
        state.layerGeometryOverrides = snapshot.geometry

        var editableKeys = Set(inspectorShaderGroups.flatMap { group in
            group.knobs.map(\.key)
        })
        editableKeys.formUnion(GlassLabTuning.shaderColorKeys.map(\.key))
        editableKeys.formUnion(GlassLabTuning.shaderPointKeys.map(\.key))
        let valueKeys = Set(snapshot.shader.keys)
            .union(snapshot.shaderColors.keys)
            .union(snapshot.shaderPoints.keys)
        state.shaderNilOverrides = snapshot.shaderInputKeys?
            .intersection(editableKeys)
            .subtracting(valueKeys) ?? []
        state.shaderOverridesEnabled = true
    }

    private func installHighlightOverrides(from snapshot: LiveReadoutSnapshot) {
        state.highlightOverrides = snapshot.highlight
        state.highlightColorOverrides = snapshot.highlightColors
        let editableKeys = Set(GlassLabTuning.highlightKnobs.map(\.key))
            .union(GlassLabTuning.highlightColorKeys.map(\.key))
        let valueKeys = Set(snapshot.highlight.keys)
            .union(snapshot.highlightColors.keys)
        state.highlightNilOverrides = snapshot.highlightInputKeys?
            .intersection(editableKeys)
            .subtracting(valueKeys) ?? []
        state.highlightOverridesEnabled = true
    }

    private func clearShaderOverridePayload() {
        state.shaderOverrides = [:]
        state.shaderNilOverrides = []
        state.shaderColorOverrides = [:]
        state.shaderPointOverrides = [:]
        state.layerGeometryOverrides = [:]
    }

    private func clearHighlightOverridePayload() {
        state.highlightOverrides = [:]
        state.highlightNilOverrides = []
        state.highlightColorOverrides = [:]
    }

    private func installVibrantMatrixOverrides(
        _ payload: [String: GlassLabTuning.VibrantColorMatrixOverridePayload]
    ) {
        state.vibrantMatrixOverrides = payload
        state.vibrantMatrixOverridesEnabled = true
    }

    private func clearVibrantMatrixOverridePayload() {
        state.vibrantMatrixOverrides = [:]
    }

    /// Rebuild only the glass view, preserving its host window and real
    /// key/main participation while discarding mutated private filter trees.
    private func rebuildAllGlassSurfaces() {
        state.testWindow.rebuildGlass(with: state)
        scheduleLiveReadoutRefresh(refreshSchema: true)
    }

    // MARK: Tools

    private func copyReport() {
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

    private func copyPassInventoryReport() {
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

    private func copySemanticReport() {
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

    private func exportSemanticUsageTrees() {
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
    private func settleSemanticExportContext(
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
    private func settleSemanticRender(capturesSnapshot: Bool) async throws
        -> GlassLabSemanticSnapshot? {
        if capturesSnapshot {
            return try await captureSettledSemanticSnapshot()
        }
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        return nil
    }

    @MainActor
    private func captureSettledSemanticSnapshot() async throws
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

    private func exportPassAudit() {
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

    private func exportMatrix() {
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
    private func waitUntilApplicationIsActive(progress: String) async throws {
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

    private func validateMatrix(
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

    private func validatePassAudit(
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

    private func matrixIdentity(
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
    private func restoreTestWindowContext(
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

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Row label

/// Toggle/row label with an inline secondary description matching the Form's
/// settings rows.
/// Shared trailing-control metrics so the Slider and value columns align
/// across every Inspector section.
private enum InspectorLayout {
    static let sliderWidth: CGFloat = 260
    static let valueWidth: CGFloat = 72
}

/// Row scaffold matching the Form sections above the Inspector: the name
/// with a compact data caption underneath on the leading side, the
/// control and value at the trailing end of the row.
private func knobRowScaffold<Control: View>(
    title: String,
    signalTag: String?,
    caption: String,
    help: String,
    isCaptionHighlighted: Bool = false,
    @ViewBuilder control: () -> Control
) -> some View {
    HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 5) {
                Text(caption)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCaptionHighlighted ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                if let signalTag {
                    Text(signalTag)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        control()
    }
    .help(help)
}

/// A scalar or sentinel Inspector row that owns its drag gesture locally.
/// Slider ticks stamp straight onto the live glass and invalidate only this
/// row; the observable override dictionary is committed once when the gesture
/// ends. Committing per tick re-evaluates the entire Form and restamps the
/// full captured payload, which stalls every Inspector drag.
private struct GlassKnobSliderRow: View {
    let knob: GlassLabTuning.Knob
    let range: ClosedRange<Double>
    let caption: String
    let help: String
    let signalTag: String?
    let liveValue: Double?
    let missingValueLabel: String
    let isEditable: Bool
    let sentinel: Double?
    @Binding var overrideValue: Double?
    let stampLive: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        knobRowScaffold(
            title: knob.label,
            signalTag: signalTag,
            caption: caption,
            help: help
        ) {
            if let sentinel {
                Toggle("Unbounded", isOn: sentinelBinding(sentinel))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(!isEditable)
                    .fixedSize()
            }
            Slider(value: sliderBinding, in: range) { editing in
                guard !editing, let value = dragValue else { return }
                dragValue = nil
                overrideValue = value
            }
            .disabled(!isEditable || usesSentinel)
            .opacity(isDimmed ? 0.4 : 1)
            .frame(width: InspectorLayout.sliderWidth)

            TextField(
                "",
                value: Binding<Double?> {
                    dragValue ?? overrideValue ?? liveValue
                } set: { value in
                    overrideValue = value
                },
                format: .number.precision(.fractionLength(0...3)),
                prompt: Text(missingValueLabel)
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.callout.monospacedDigit())
            .foregroundStyle(
                overrideValue == nil && dragValue == nil ? Color.secondary : Color.orange
            )
            .disabled(!isEditable)
            .frame(width: InspectorLayout.valueWidth, alignment: .trailing)
        }
    }

    private var currentValue: Double? {
        dragValue ?? overrideValue ?? liveValue
    }

    private var usesSentinel: Bool {
        guard let sentinel else { return false }
        return abs((currentValue ?? knob.fallback) - sentinel) < 0.0001
    }

    /// A nil-valued input renders dimmed at its fallback position until a
    /// drag or override populates it.
    private var isDimmed: Bool {
        usesSentinel || currentValue == nil
    }

    private var sliderBinding: Binding<Double> {
        Binding {
            min(max(currentValue ?? knob.fallback, range.lowerBound), range.upperBound)
        } set: { value in
            dragValue = value
            stampLive(value)
        }
    }

    private func sentinelBinding(_ sentinel: Double) -> Binding<Bool> {
        Binding {
            usesSentinel
        } set: { enabled in
            dragValue = nil
            overrideValue = enabled ? sentinel : range.lowerBound
        }
    }
}

private struct LabRowLabel: View {
    let title: String
    let description: String?

    init(_ title: String, description: String? = nil) {
        self.title = title
        self.description = description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    GlassLabView(state: GlassLabState())
}
#endif
