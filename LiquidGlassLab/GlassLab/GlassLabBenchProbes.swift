//
//  GlassLabBenchProbes.swift
//  LiquidGlassLab
//
//  Bench: mutation-contract probes — the Variant 14 aberration probe and
//  the Regular/Clear vibrant-matrix 8-case suite, with their report types
//  and UI panels. Audit tools, not accepted material controls.
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension GlassLabView {
    /// The Bench Probes page. Both probes act on the live Recipe pass tree;
    /// the hidden `.passes` context page keeps the pass inventory publishing
    /// while this page is active.
    @ViewBuilder
    func benchProbeSections(state labState: GlassLabState) -> some View {
        let items = passInventorySnapshot.map(passInventoryItems) ?? []
        if let foreground = items.first(where: { $0.family == "glassForeground" }) {
            foregroundAberrationProbeSections(item: foreground)
        } else {
            labBox {
                Text("The aberration probe needs the glassForeground pass, which only Variant 14 exposes. Set the Recipe variant to 14 with the test window visible to arm it.")
                    .foregroundStyle(.secondary)
            }
        }

        vibrantColorMatrixProbeSections()
    }

    @ViewBuilder
    func foregroundAberrationProbeSections(
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
    func vibrantColorMatrixProbeSections() -> some View {
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

    struct ForegroundProbeReport: Equatable {
        let requestedValue: String
        let before: GlassLabTuning.ForegroundAberrationProbeObservation
        let immediate: GlassLabTuning.ForegroundAberrationProbeObservation
        let settled: GlassLabTuning.ForegroundAberrationProbeObservation

        var objectWasReplaced: Bool {
            before.objectIdentity != settled.objectIdentity
        }
    }

    enum VibrantMatrixMutationKind: String {
        case booleans = "Boolean vector"
        case matrix = "Matrix coefficient"
    }

    struct VibrantMatrixMutationReport {
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

    struct VibrantMatrixCaseReport: Identifiable {
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

    var foregroundProbeContextIsReady: Bool {
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
    func prepareForegroundProbeBaseline() {
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

    func runForegroundAberrationProbe(
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

    func resetForegroundAberrationProbe() {
        cancelForegroundProbe(clearReport: true)
        state.testWindow.rebuildGlass(with: state)
        foregroundProbeStatus = "The private filter tree was rebuilt from the current Recipe."
        scheduleLiveReadoutRefresh(refreshSchema: true)
    }

    func cancelForegroundProbe(clearReport: Bool) {
        foregroundProbeTask?.cancel()
        foregroundProbeTask = nil
        isForegroundProbeRunning = false
        if clearReport {
            foregroundProbeReport = nil
            foregroundProbeStatus = nil
        }
    }

    func finishForegroundProbeFailure(_ message: String) {
        foregroundProbeReport = nil
        foregroundProbeStatus = message
        isForegroundProbeRunning = false
        foregroundProbeTask = nil
        scheduleLiveReadoutRefresh()
    }

    func probeValue(
        _ observation: GlassLabTuning.ForegroundAberrationProbeObservation,
        presentation: Bool
    ) -> String {
        if presentation {
            return observation.presentationValue ?? observation.presentationState
        }
        return observation.modelValue ?? observation.modelState
    }

    func foregroundProbeReportText(_ report: ForegroundProbeReport) -> String {
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

    func runVibrantColorMatrixProbeSuite() {
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
    func settleVibrantMatrixProbeContext(
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

    func vibrantColorMatrixPasses(
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
    func runVibrantMatrixMutationProbe(
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
    func captureVibrantMatrixProbePair(
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

    func vibrantMatrixProbeReportText(
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
}
#endif
