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
    /// Recipe pages. `.materialize` and `.tint` survive as hidden context
    /// state — the Bench pages and capture drivers still arm the materialize
    /// probe and the pass-snapshot publisher through them — but the product
    /// picker offers only `productCases`.
    enum RecipePage: String, CaseIterable, Identifiable {
        case general = "General"
        case passes = "Passes"
        case materialize = "Materialize"
        case tint = "Tint"

        var id: Self { self }

        static let productCases: [RecipePage] = [.general, .passes]
    }

    /// Semantic pages. `.transition` survives as hidden context state for the
    /// same reason as the hidden Recipe pages.
    enum SemanticPage: String, CaseIterable, Identifiable {
        case general = "General"
        case layerInspector = "Layer Inspector"
        case transition = "Transition"

        var id: Self { self }

        static let productCases: [SemanticPage] = [.general, .layerInspector]
    }

    /// The research area. Every page here is instrumentation: it may steer
    /// `rendererMode` and the hidden context pages, and it hosts all capture,
    /// probe, study, and export UI.
    enum BenchPage: String, CaseIterable, Identifiable {
        case exports = "Baseline"
        case atlas = "Product"
        case probes = "Verification"
        case materialize = "Advanced · Materialize"
        case tint = "Advanced · Tint"
        case transition = "Advanced · Transition"

        var id: Self { self }
    }

    let state: GlassLabState
    @State var selectedRecipePage = RecipePage.general
    @State var selectedPassSlotID: String?
    @State var selectedSemanticPage = SemanticPage.general
    @State var selectedBenchPage = BenchPage.exports
    @State var isCapturingMatrix = false
    @State var isCapturingSemanticTrees = false
    @State var liveSnapshot: LiveReadoutSnapshot?
    @State var passInventorySnapshot: GlassLabTuning.PassAuditSnapshot?
    @State var passObjectIdentityBySlot: [String: ObjectIdentifier] = [:]
    @State var replacedPassSlots: Set<String> = []
    @State var semanticSnapshot: GlassLabSemanticSnapshot?
    @State var materializeAnimationMode:
        GlassLabMaterializeAnimationMode = .systemDefault
    @State var materializeLinearDuration = 4.0
    @State var materializeRequestedMain = false
    @State var materializeRequestedAppearance:
        GlassLabTestAppearance = .system
    @State var materializeRequestedBackdrop:
        GlassLabBackdropMode = .ambient
    /// The geometry the probe is currently waiting to settle into. Fixed at the
    /// baseline 480×200 for every page and study except the geometry sweep.
    @State var materializeRequestedSize = CGSize(
        width: 480,
        height: 200
    )
    @State var materializePresented = true
    @State var materializeCapture: GlassLabMaterializeCapture?
    @State var materializeCaptureStatus: String?
    @State var materializeCaptureTask: Task<Void, Never>?
    @State var isCapturingMaterialize = false
    @State var materializeStudyDocument:
        GlassLabMaterializeStudyDocument?
    @State var materializeStudyStatus: String?
    @State var materializeStudyTask: Task<Void, Never>?
    @State var isCapturingMaterializeStudy = false
    @State var appKitMaterializeVariant = 1
    @State var appKitMaterializeRequestedMain = false
    @State var appKitMaterializeProgress = 1.0
    @State var appKitMaterializeIncludesViewEnvelope = false
    @State var appKitMaterializeResult:
        GlassLabTuning.MaterializeBackgroundTransplantResult?
    @State var appKitMaterializeStatus: String?
    @State var appKitMaterializeTask: Task<Void, Never>?
    @State var isAnimatingAppKitMaterialize = false
    @State var tintStudyDocument: GlassLabTintStudyDocument?
    @State var tintStudyStatus: String?
    @State var tintStudyTask: Task<Void, Never>?
    @State var isCapturingTintStudy = false
    @State var tintParameterizationDocument:
        GlassLabTintParameterizationSweepDocument?
    @State var tintParameterizationStatus: String?
    @State var tintParameterizationTask: Task<Void, Never>?
    @State var isCapturingTintParameterization = false
    @State var tintRenderedABDocument: GlassLabTintRenderedABDocument?
    @State var tintRenderedABStatus: String?
    @State var tintRenderedABTask: Task<Void, Never>?
    @State var isCapturingTintRenderedAB = false
    @State var shaderOverrideBaseline: LiveReadoutSnapshot?
    @State var highlightOverrideBaseline: LiveReadoutSnapshot?
    @State var vibrantMatrixOverrideBaseline:
        [String: GlassLabTuning.VibrantColorMatrixOverridePayload]?
    @State var inspectorShaderGroups: [GlassLabTuning.ShaderKnobGroup] = []
    @State var inspectorShaderMetadata: [String: GlassLabTuning.AttributeMetadata] = [:]
    @State var inspectorHighlightMetadata: [String: GlassLabTuning.AttributeMetadata] = [:]
    @State var liveRefreshTask: Task<Void, Never>?
    @State var matrixCaptureTask: Task<Void, Never>?
    @State var semanticCaptureTask: Task<Void, Never>?
    @State var foregroundProbeTask: Task<Void, Never>?
    @State var foregroundProbeReport: ForegroundProbeReport?
    @State var foregroundProbeStatus: String?
    @State var isForegroundProbeRunning = false
    @State var vibrantMatrixProbeTask: Task<Void, Never>?
    @State var vibrantMatrixProbeReports: [VibrantMatrixCaseReport] = []
    @State var vibrantMatrixProbeStatus: String?
    @State var isVibrantMatrixProbeRunning = false
    @State var hasPendingSchemaRefresh = false
    @State var atlasDocument: GlassMaterialStyleAtlas?
    @State var atlasStatus: String?
    @State var atlasCaptureTask: Task<Void, Never>?
    @State var isCapturingAtlas = false
    @State var atlasReadbackReport: String?
    @State var atlasReadbackTask: Task<Void, Never>?
    @State var isRunningAtlasReadback = false
    @State var atlasProvider: GlassMaterialAtlasProvider?
    @State var providerStatus: String?
    @State var hudPanelController: GlassLabHUDPanelController?
    @State var hudStatusRevision = 0
    @State var hudPanelVisible = false
    @State var hudAppearance = GlassLabHUDPanelController.Appearance.auto
    @State var hudIsClear = false
    @State var hudIsMuted = false
    @State var hudStrength = 1.0
    @State var hudTintEnabled = false
    @State var hudTint = Color(red: 1, green: 0.45, blue: 0.35).opacity(0.6)
    @State var tintLockTask: Task<Void, Never>?
    @State var hudContentWidth = 320.0
    @State var hudContentHeight = 120.0
    @State var hudRenderExperimentExpanded = false
    @State var hudExperimentalOuterPasses: AdjustableGlassOuterPasses = [
        .ringShadow,
        .bleed,
        .outerRefraction,
    ]
    @State var hudExperimentalMarginWidth: Double? = 0

    var body: some View {
        labForm
        .background(GlassLabControlWindowAnchor(state: state).frame(width: 0, height: 0))
        .navigationTitle(state.selectedSection.navigationTitle)
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
        .onChange(of: state.selectedSection) {
            applyBenchPageContext()
        }
        .onChange(of: selectedBenchPage) {
            applyBenchPageContext()
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
            semanticCaptureTask?.cancel()
            foregroundProbeTask?.cancel()
            vibrantMatrixProbeTask?.cancel()
            materializeCaptureTask?.cancel()
            materializeStudyTask?.cancel()
            appKitMaterializeTask?.cancel()
            tintStudyTask?.cancel()
            tintParameterizationTask?.cancel()
            tintRenderedABTask?.cancel()
            atlasCaptureTask?.cancel()
            atlasReadbackTask?.cancel()
            tintLockTask?.cancel()
            hudPanelController?.tearDown()
        }
    }

    private var labForm: some View {
        labFormContent(snapshot: liveSnapshot)
    }

    /// Bench pages steer the renderer and the hidden context pages so the
    /// existing probe wiring — materialize arm/cancel on `selectedRecipePage`,
    /// transition probe configuration on `selectedSemanticPage`, and the
    /// pass-snapshot publisher's `.passes` gate — keeps working unchanged.
    /// Leaving Bench (or a Bench page) resets any research page it had set,
    /// which is also what disarms its instrumentation.
    private func applyBenchPageContext() {
        guard state.selectedSection == .bench else {
            if selectedRecipePage == .materialize || selectedRecipePage == .tint {
                selectedRecipePage = .general
            }
            if selectedSemanticPage == .transition {
                selectedSemanticPage = .general
            }
            return
        }
        switch selectedBenchPage {
        case .atlas:
            state.rendererMode = .recipe
            // `.passes` counts as a research page here too: leaving Probes
            // for this page must disarm the recursive pass audit, which
            // only the Probes (or Recipe Passes) UI consumes.
            if selectedRecipePage == .materialize || selectedRecipePage == .tint
                || selectedRecipePage == .passes {
                selectedRecipePage = .general
            }
            if selectedSemanticPage == .transition {
                selectedSemanticPage = .general
            }
        case .exports:
            if selectedRecipePage == .materialize || selectedRecipePage == .tint
                || selectedRecipePage == .passes {
                selectedRecipePage = .general
            }
            if selectedSemanticPage == .transition {
                selectedSemanticPage = .general
            }
        case .materialize:
            state.rendererMode = .recipe
            selectedRecipePage = .materialize
            if selectedSemanticPage == .transition {
                selectedSemanticPage = .general
            }
        case .tint:
            state.rendererMode = .recipe
            selectedRecipePage = .tint
            if selectedSemanticPage == .transition {
                selectedSemanticPage = .general
            }
        case .transition:
            state.rendererMode = .semanticUsage
            selectedSemanticPage = .transition
            if selectedRecipePage == .materialize || selectedRecipePage == .tint {
                selectedRecipePage = .general
            }
        case .probes:
            state.rendererMode = .recipe
            selectedRecipePage = .passes
            if selectedSemanticPage == .transition {
                selectedSemanticPage = .general
            }
        }
    }

    private func labFormContent(snapshot: LiveReadoutSnapshot?) -> some View {
        @Bindable var state = state
        return VStack(spacing: 0) {
            Group {
                switch state.selectedSection {
                case .recipe:
                    Picker("Recipe Page", selection: $selectedRecipePage) {
                        ForEach(RecipePage.productCases) { page in
                            Text(page.rawValue).tag(page)
                        }
                    }
                case .semanticUsage:
                    Picker("Semantic Page", selection: $selectedSemanticPage) {
                        ForEach(SemanticPage.productCases) { page in
                            Text(page.rawValue).tag(page)
                        }
                    }
                case .bench:
                    Picker("Bench Page", selection: $selectedBenchPage) {
                        ForEach(BenchPage.allCases) { page in
                            Text(page.rawValue).tag(page)
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(
                isCapturingTintStudy
                    || isCapturingTintParameterization
                    || isCapturingTintRenderedAB
            )
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider()

            if state.selectedSection == .recipe, selectedRecipePage == .passes {
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
                        || isCapturingSemanticTrees
                        || isCapturingTintStudy
                )
            } else if state.selectedSection == .bench, selectedBenchPage == .probes {
                // Probes share the Passes page's card styling, so they render
                // outside the Form for the same single-platter reason.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        benchProbeSections(state: state)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(
                    isCapturingMatrix
                        || isCapturingSemanticTrees
                        || isCapturingTintStudy
                )
            } else {
            Form {
                switch state.selectedSection {
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

                case .passes, .materialize, .tint:
                    EmptyView()
                }

                case .semanticUsage:
                switch selectedSemanticPage {
                case .general:
                    semanticGeneralSections(state: state)
                case .layerInspector:
                    semanticInspectorSections(state: state, snapshot: semanticSnapshot)
                case .transition:
                    EmptyView()
                }

                case .bench:
                switch selectedBenchPage {
                case .atlas:
                    benchAtlasSections(state: state)
                case .exports:
                    benchExportSections(state: state)
                case .materialize:
                    appKitMaterializeSections(state: state)
                case .tint:
                    tintStudySections(state: state)
                case .transition:
                    semanticTransitionSections(state: state)
                case .probes:
                    EmptyView()
                }

                }
        }
        .formStyle(.grouped)
        .disabled(
            isCapturingMatrix
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
    func controlGroupCard<Content: View>(
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
            case "vibrantColorMatrix":
                vibrantColorMatrixEditorSections(
                    item: selectedItem,
                    state: labState
                )
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
    func labBox<Content: View>(
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

    func labeledSlider(
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

    func formatKnobValue(_ value: Double) -> String {
        String(format: "%.4g", value)
    }

    private func formatRangeValue(_ value: Double) -> String {
        String(format: "%.3g", value)
    }

    struct LiveReadoutSnapshot: Equatable {
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

    struct PassInventoryItem: Identifiable {
        let record: GlassLabTuning.PassAuditPassRecord
        let channel: String
        let family: String
        let ordinal: Int
        let familyCount: Int

        var id: String { record.id }
        var slotID: String { "\(record.layerPath)|\(record.location)" }
    }

    func passInventoryItems(
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

    func passState(
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

    var selectedReadoutGlass: NSGlassEffectView? {
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
    func scheduleLiveReadoutRefresh(refreshSchema: Bool = false) {
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
    func publishLiveReadoutSnapshot() {
        let snapshot = captureLiveReadoutSnapshot()
        if snapshot != liveSnapshot {
            liveSnapshot = snapshot
        }
    }

    func publishPassInventorySnapshot() {
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

    var tintBinding: Binding<Color> {
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
    var overridesEnabledBinding: Binding<Bool> {
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

    func clearShaderOverridePayload() {
        state.shaderOverrides = [:]
        state.shaderNilOverrides = []
        state.shaderColorOverrides = [:]
        state.shaderPointOverrides = [:]
        state.layerGeometryOverrides = [:]
    }

    func clearHighlightOverridePayload() {
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

    func clearVibrantMatrixOverridePayload() {
        state.vibrantMatrixOverrides = [:]
    }

    /// Rebuild only the glass view, preserving its host window and real
    /// key/main participation while discarding mutated private filter trees.
    private func rebuildAllGlassSurfaces() {
        state.testWindow.rebuildGlass(with: state)
        scheduleLiveReadoutRefresh(refreshSchema: true)
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

    @State var dragValue: Double?

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

struct LabRowLabel: View {
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
