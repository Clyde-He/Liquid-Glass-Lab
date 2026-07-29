//
//  GlassLabBenchMaterialize.swift
//  LiquidGlassLab
//
//  Bench: the Materialize research pages and their drivers — the AppKit
//  transplant probe, the semantic transition capture, the 64-run P1 study,
//  and their exports.
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension GlassLabView {
    @ViewBuilder
    func appKitMaterializeSections(
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
    func semanticTransitionSections(
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
                Text(Self.previewContextSummary(state: state))
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

    var appKitMaterializeProbeContextIsReady: Bool {
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

    var appKitMaterializeProgressBinding: Binding<Double> {
        Binding {
            appKitMaterializeProgress
        } set: { value in
            setAppKitMaterializeProgress(value)
        }
    }

    var appKitMaterializeViewEnvelopeBinding: Binding<Bool> {
        Binding {
            appKitMaterializeIncludesViewEnvelope
        } set: { enabled in
            appKitMaterializeIncludesViewEnvelope = enabled
            applyAppKitMaterializeProgress()
        }
    }

    var appKitMaterializeTintBinding: Binding<Color> {
        Binding {
            state.tintColor.map(Color.init) ?? Color.black.opacity(0)
        } set: { color in
            let nsColor = NSColor(color)
            setAppKitMaterializeTint(
                nsColor.alphaComponent > 0 ? nsColor : nil
            )
        }
    }

    func setAppKitMaterializeTint(_ color: NSColor?) {
        state.tintColor = color
        requestAppKitMaterializeProbeContext()
    }

    func requestAppKitMaterializeProbeContext() {
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

    func waitForAppKitMaterializeProbeContext() async throws -> Bool {
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

    func setAppKitMaterializeProgress(_ progress: Double) {
        appKitMaterializeProgress = min(max(progress, 0), 1)
        applyAppKitMaterializeProgress()
    }

    func applyAppKitMaterializeProgress(
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

    func animateAppKitMaterialize(to target: Double) {
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

    func cancelAppKitMaterializeProbe(rebuild: Bool) {
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

    var materializeProbeContextIsReady: Bool {
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

    func configureSemanticTransitionProbe() {
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

    func requestMaterializeCaptureContext(
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

    func waitForMaterializeCaptureContext() async throws -> Bool {
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

    func runManualMaterializeTransition(
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

    func cancelMaterializeCapture() {
        materializeCaptureTask?.cancel()
        materializeCaptureTask = nil
        isCapturingMaterialize = false
    }

    func captureMaterializeTransition(
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

    func captureFullMaterializeStudy() {
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

    func exportMaterializeStudy() {
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
    func performMaterializeCapture(
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
        let preflight: GlassLabSemanticTransitionSnapshot
        if direction == .removal {
            // Prepare removal through the real lifecycle: a fresh hidden
            // subtree materializes in, then Materialize Out starts from the
            // same settled insertion endpoint recorded by an insertion run.
            // At shortSide 48 that endpoint has a different face grade from
            // the long-lived static Recipe, so waiting for general Recipe
            // stability here would silently replace the endpoint under study.
            materializePresented = false
            state.testWindow.resetSemanticTransitionProbe(presented: false)
            // Let the absent subtree commit before publishing the presented
            // state. Without this boundary SwiftUI coalesces false → true and
            // constructs an already-presented static Recipe instead of
            // running the warm-up materialization.
            _ = try await captureSettledMaterializePreflight()
            let warmupStart = Date()
            materializePresented = true
            let warmupDuration = animationMode == .linear
                ? linearDuration
                : 0.8
            state.testWindow.setSemanticTransitionPresented(
                true,
                animationMode: .linear,
                linearDuration: warmupDuration
            )
            preflight = try await captureMaterializedInsertionEndpoint(
                startedAt: warmupStart,
                duration: warmupDuration
            )
        } else {
            materializePresented = initialPresented
            state.testWindow.resetSemanticTransitionProbe(
                presented: initialPresented
            )
            preflight = try await captureSettledMaterializePreflight()
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

    /// Captures the same terminal state as an ordinary insertion run: the
    /// animation duration plus its 100 ms settled observation. Do not use the
    /// general Recipe-stability loop here. A compact glass can leave this
    /// Materialized endpoint and adopt its long-lived static face grade later,
    /// which is precisely the history-dependent state removal must preserve.
    @MainActor
    func captureMaterializedInsertionEndpoint(
        startedAt start: Date,
        duration animationDuration: Double
    ) async throws -> GlassLabSemanticTransitionSnapshot {
        let remaining = animationDuration - Date().timeIntervalSince(start)
        if remaining > 0 {
            try await Task.sleep(for: .seconds(remaining))
        }
        try Task.checkCancellation()
        try await requireMaterializeContext()
        guard captureCurrentMaterializeSnapshot() != nil else {
            throw TintStudyError.missingSemanticSnapshot
        }
        // An insertion run records its requested endpoint first, then waits
        // 100 ms and records the settled endpoint. Preserve both the clock
        // origin and that intervening full-tree read; compact Main-On grading
        // can still move inside this small terminal window.
        try await Task.sleep(for: .milliseconds(100))
        try await requireMaterializeContext()
        guard let snapshot = captureCurrentMaterializeSnapshot() else {
            throw TintStudyError.missingSemanticSnapshot
        }
        let faceProgress = snapshot.model.filters
            .first { $0.name == "glassBackground" }?
            .inputs
            .first { $0.key == "inputFaceOpacity" }
            .flatMap { Double($0.value) }
        guard let faceProgress, faceProgress >= 0.999 else {
            throw TintStudyError.contextRejected(
                "Materialize In warm-up did not reach its presented endpoint"
            )
        }
        return snapshot
    }

    /// Context truth and material endpoint stability are separate conditions.
    /// The window can already report the requested size/appearance/Main state
    /// while SwiftUI is still replacing or retiring the private Recipe
    /// underneath it. Require the model tree to agree across observations
    /// after 360 ms rather than naming one fixed delay "settled".
    @MainActor
    func captureSettledMaterializePreflight() async throws
        -> GlassLabSemanticTransitionSnapshot
    {
        var previousModel: GlassLabSemanticSnapshot?
        var latest: GlassLabSemanticTransitionSnapshot?
        var elapsedMilliseconds = 0

        for delayMilliseconds in [120, 120, 120, 120, 240] {
            try await Task.sleep(for: .milliseconds(delayMilliseconds))
            try Task.checkCancellation()
            try await requireMaterializeContext()
            guard let current = captureCurrentMaterializeSnapshot() else {
                continue
            }
            elapsedMilliseconds += delayMilliseconds
            if elapsedMilliseconds >= 360, current.model == previousModel {
                return current
            }
            previousModel = current.model
            latest = current
        }
        guard let latest else {
            throw TintStudyError.missingSemanticSnapshot
        }
        return latest
    }

    @MainActor
    func requireMaterializeContext() async throws {
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
    func captureCurrentMaterializeSnapshot()
        -> GlassLabSemanticTransitionSnapshot? {
        state.testWindow.liveWindow?.contentView?.layoutSubtreeIfNeeded()
        state.testWindow.liveWindow?.contentView?.displayIfNeeded()
        return GlassLabSemanticTransitionSnapshot.capture(
            from: state.testWindow.liveSemanticLayerRoot
        )
    }

    func candidateMaterializeDuration(
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

    func copyMaterializeCaptureReport() {
        guard let capture = materializeCapture else { return }
        state.reportOutput = capture.report
        copyToPasteboard(capture.report)
    }

    func exportMaterializeCapture() {
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
}
#endif
