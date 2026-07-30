//
//  GlassLabBenchHeadless.swift
//  LiquidGlassLab
//
//  Bench: the headless CLI harness (--capture-golden and friends) plus the
//  pass/fail acceptance checks it drives: resize restamp, removal warmup,
//  and the geometry size study.
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension GlassLabView {
    /// Drives the last open P1 exit criterion: a resize forces AppKit to
    /// re-resolve the Recipe and hand back a fresh tree, and the authored
    /// strength must survive that without being reverted to the system value
    /// and without being stuck on the previous size's endpoints.
    ///
    /// The strength is written once at the starting size and never re-applied.
    /// Everything observed afterwards comes from the layout restamp alone.
    @MainActor
    func performResizeRestampCheck() async throws -> [String: Any] {
        let strength = 0.5
        let sizes: [Double] = [200, 400, 96, 200]
        let variant = 1
        // inputFaceOpacity's endpoint is always 1, so it reads back as the
        // strength itself and is a size-independent sentinel: a reverted tree
        // reports 1.
        // inputShadowHeight's endpoint is 0.4 * shortSide, so it proves the
        // baseline was recaptured for the new geometry instead of being reused.
        let shapeAt = { (g: Double, shortSide: Double) -> Double in
            g + min(0.2, 16 / shortSide) * g * (1 - g)
        }

        state.rendererMode = .recipe
        state.variant = variant
        state.subvariant = ""
        state.isSubdued = false
        state.hasScrim = false
        state.tintColor = nil
        state.windowHostType = .panel
        state.testAppearance = .light
        state.testBackdrop = .light
        state.isTestWindowMain = false
        state.windowPadding = 40
        state.cornerRadius = 16
        state.glassWidth = 480
        state.glassHeight = sizes[0]
        state.isTestWindowVisible = true
        state.testWindow.sync(with: state)
        try await Task.sleep(for: .milliseconds(600))

        var steps: [[String: Any]] = []
        state.testWindow.applyAppKitMaterializeBackgroundProbe(
            progress: strength,
            variant: variant,
            requestedMain: false,
            tintColor: nil,
            includesViewEnvelope: false
        )
        try await Task.sleep(for: .milliseconds(240))

        for (index, size) in sizes.enumerated() {
            if index > 0 {
                state.glassHeight = size
                state.testWindow.sync(with: state)
                // Let AppKit re-resolve and the layout restamp run.
                try await Task.sleep(for: .milliseconds(600))
            }
            guard let glass = state.testWindow.liveGlass else {
                throw TintStudyError.contextRejected("No live glass")
            }
            let inputs = GlassLabTuning.captureShaderInputs(from: glass)
            let shortSide = min(glass.bounds.width, glass.bounds.height)
            let faceOpacity = inputs["inputFaceOpacity"] ?? -1
            let shadowHeight = inputs["inputShadowHeight"] ?? -1
            let expectedShadowHeight =
                0.4 * shortSide * shapeAt(strength, shortSide)
            let faceOK = abs(faceOpacity - strength) < 0.01
            let shadowOK = abs(shadowHeight - expectedShadowHeight)
                <= max(0.05, expectedShadowHeight * 0.02)
            steps.append([
                "step": index,
                "requestedShortSide": size,
                "actualShortSide": shortSide,
                "resized": index > 0,
                "inputFaceOpacity": faceOpacity,
                "expectedFaceOpacity": strength,
                "faceOpacityHeld": faceOK,
                "inputShadowHeight": shadowHeight,
                "expectedShadowHeight": expectedShadowHeight,
                "shadowHeightFollowedSize": shadowOK,
                "passed": faceOK && shadowOK,
            ])
        }

        state.testWindow.clearAppKitMaterializeBackgroundProbe(rebuild: true)
        let failures = steps.filter { ($0["passed"] as? Bool) != true }
        return [
            "formatVersion": 1,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "operatingSystem":
                ProcessInfo.processInfo.operatingSystemVersionString,
            "strength": strength,
            "variant": variant,
            "sizeSequence": sizes,
            "steps": steps,
            "passed": failures.isEmpty,
            "failureCount": failures.count,
        ]
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
    func runHeadlessCaptureIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        let sizeFlag = arguments.firstIndex(of: "--capture-size-study")
        let resizeFlag = arguments.firstIndex(of: "--verify-resize-restamp")
        let removalWarmupFlag = arguments.firstIndex(
            of: "--verify-removal-warmup"
        )
        let goldenFlag = arguments.firstIndex(of: "--capture-golden")
        let planFlag = arguments.firstIndex(of: "--print-golden-plan")
        let atlasFlag = arguments.firstIndex(of: "--verify-style-atlas")
        let tintParameterizationFlag = arguments.firstIndex(
            of: "--capture-tint-parameterization"
        )
        let tintParameterizationFocusedFlag = arguments.firstIndex(
            of: "--capture-tint-parameterization-focused"
        )
        let tintParameterizationHueFlag = arguments.firstIndex(
            of: "--capture-tint-parameterization-phase-2c"
        )
        guard let flagIndex = sizeFlag
                ?? resizeFlag
                ?? removalWarmupFlag
                ?? goldenFlag
                ?? atlasFlag
                ?? tintParameterizationHueFlag
                ?? tintParameterizationFocusedFlag
                ?? tintParameterizationFlag
                ?? planFlag else {
            return
        }
        // A capture flag without its output path must fail loudly: silently
        // falling through leaves a normal GUI app idling in the event loop,
        // which reads as a hung verification from the outside.
        guard arguments.index(after: flagIndex) < arguments.endIndex
                || planFlag != nil else {
            FileHandle.standardError.write(Data(
                "\(arguments[flagIndex]) requires an output path argument\n"
                    .utf8
            ))
            exit(64)
        }
        // The plan is pure data, so it can be reported without a window, an
        // activation, or a single private read. Checking the shape of a capture
        // before paying for it is the point.
        if planFlag != nil {
            FileHandle.standardError.write(Data(
                (Self.goldenPlanReport() + "\n").utf8
            ))
            exit(0)
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
            if tintParameterizationFlag != nil
                || tintParameterizationFocusedFlag != nil
                || tintParameterizationHueFlag != nil {
                let plan: GlassLabTintSweepPlan
                if tintParameterizationHueFlag != nil {
                    plan = .hueFractionPhase2c
                } else if tintParameterizationFocusedFlag != nil {
                    plan = .focusedPhase2b
                } else {
                    plan = .fullGridV1
                }
                let document = try await captureTintParameterizationSweep(
                    into: destination,
                    plan: plan
                )
                let report = "== Tint Parameterization Sweep ==\n"
                    + "Plan: \(document.plan.id)\n"
                    + "Colors: \(document.completedColorCount)/"
                    + "\(document.plan.colors.count)\n"
                    + "Rows: \(document.rows.count)\n"
                    + "Unclassified: \(document.unclassifiedRowCount)\n"
                    + "Complete: \(document.complete ? "yes" : "no")"
                FileHandle.standardError.write(Data(
                    (report + "\nWrote \(destination.path)\n").utf8
                ))
                state.testWindow.tearDown()
                exit(0)
            }
            let payload: Data
            let report: String
            if goldenFlag != nil {
                // The Golden exporter writes a directory of its own, so it
                // reports rather than handing back one payload to write.
                let meta = try await captureGoldenArchive(into: destination)
                FileHandle.standardError.write(Data(
                    (Self.goldenReport(meta) + "\nWrote \(destination.path)\n").utf8
                ))
                state.testWindow.tearDown()
                exit(0)
            } else if resizeFlag != nil {
                let result = try await performResizeRestampCheck()
                payload = try JSONSerialization.data(
                    withJSONObject: result,
                    options: [.prettyPrinted, .sortedKeys]
                )
                let passed = (result["passed"] as? Bool) == true
                report = "== Resize restamp check ==\n"
                    + "Steps: \((result["steps"] as? [Any])?.count ?? 0)\n"
                    + "Result: \(passed ? "PASSED" : "FAILED")"
                if !passed { exitCode = 2 }
            } else if removalWarmupFlag != nil {
                let result = try await performRemovalWarmupCheck()
                payload = try JSONSerialization.data(
                    withJSONObject: result,
                    options: [.prettyPrinted, .sortedKeys]
                )
                let passed = (result["passed"] as? Bool) == true
                report = "== Removal warm-up check ==\n"
                    + "Cells: \((result["cells"] as? [Any])?.count ?? 0)\n"
                    + "Result: \(passed ? "PASSED" : "FAILED")"
                if !passed { exitCode = 2 }
            } else if atlasFlag != nil {
                let result = try await performStyleAtlasVerification()
                payload = try JSONSerialization.data(
                    withJSONObject: result,
                    options: [.prettyPrinted, .sortedKeys]
                )
                let passed = (result["passed"] as? Bool) == true
                report = "== Style atlas verification ==\n"
                    + "Steps: \((result["steps"] as? [Any])?.count ?? 0)\n"
                    + "Failures: \(result["failureCount"] ?? "?")\n"
                    + "Result: \(passed ? "PASSED" : "FAILED")"
                if !passed { exitCode = 2 }
            } else {
                let document = try await performMaterializeSizeStudy()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                payload = try encoder.encode(document)
                report = document.report
            }
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
                (report + "\nWrote \(written.path)\n").utf8
            ))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            FileHandle.standardError.write(Data(
                "Headless capture failed: \(message)\n".utf8
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
    func performMaterializeSizeStudy() async throws
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

    /// Verifies the lifecycle seam that compact glass exposes: removal must
    /// start from the settled endpoint of a real insertion, not from either a
    /// directly-created Presented view or the later long-lived Recipe.
    @MainActor
    func performRemovalWarmupCheck() async throws -> [String: Any] {
        let glassSize = CGSize(width: 480, height: 48)
        let appearance = GlassLabTestAppearance.light
        let backdrop = GlassLabBackdropMode.light
        let tintPreset = GlassLabTintPreset.none
        let keys = [
            "inputFaceOpacity",
            "inputFaceColorMatrixBlack",
            "inputFaceColorMatrixWhite",
            "inputClamp",
        ]

        state.rendererMode = .semanticUsage
        selectedSemanticPage = .transition
        materializeAnimationMode = .linear
        materializeLinearDuration = 1
        configureSemanticTransitionProbe()

        func selectedBackgroundInputs(
            from snapshot: GlassLabSemanticTransitionSnapshot
        ) -> [String: String] {
            guard let background = snapshot.model.filters.first(where: {
                $0.name == "glassBackground"
            }) else {
                return [:]
            }
            let inputs = Dictionary(
                background.inputs.map { ($0.key, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            return Dictionary(
                uniqueKeysWithValues: keys.compactMap { key in
                    inputs[key].map { (key, $0) }
                }
            )
        }

        func maximumDifference(
            _ lhs: [String: String],
            _ rhs: [String: String]
        ) -> Double? {
            let differences = keys.compactMap { key -> Double? in
                guard let lhsValue = lhs[key].flatMap(Double.init),
                      let rhsValue = rhs[key].flatMap(Double.init) else {
                    return nil
                }
                return abs(lhsValue - rhsValue)
            }
            guard differences.count == keys.count else { return nil }
            return differences.max()
        }

        var cells: [[String: Any]] = []
        for usage in [
            GlassLabSemanticUsage.regular,
            GlassLabSemanticUsage.clear,
        ] {
            for requestedMain in [false, true] {
                let insertion = try await performMaterializeCapture(
                    usage: usage,
                    direction: .insertion,
                    animationMode: .linear,
                    linearDuration: 1,
                    requestedMain: requestedMain,
                    tint: tintPreset.descriptor,
                    tintColor: tintPreset.color,
                    appearance: appearance,
                    backdrop: backdrop,
                    glassSize: glassSize
                )
                // Resolve the alternative history explicitly. This is the
                // endpoint the old removal harness accidentally captured.
                materializePresented = true
                state.testWindow.resetSemanticTransitionProbe(presented: true)
                let directlyPresented = try await
                    captureSettledMaterializePreflight()
                let removal = try await performMaterializeCapture(
                    usage: usage,
                    direction: .removal,
                    animationMode: .linear,
                    linearDuration: 1,
                    requestedMain: requestedMain,
                    tint: tintPreset.descriptor,
                    tintColor: tintPreset.color,
                    appearance: appearance,
                    backdrop: backdrop,
                    glassSize: glassSize
                )
                guard let insertionEndpoint = insertion.samples.last?.snapshot,
                      let removalPreflight = removal.samples.first?.snapshot else {
                    throw TintStudyError.missingSemanticSnapshot
                }
                let expected = selectedBackgroundInputs(
                    from: insertionEndpoint
                )
                let staticEndpoint = selectedBackgroundInputs(
                    from: directlyPresented
                )
                let actual = selectedBackgroundInputs(
                    from: removalPreflight
                )
                let insertionDifference = maximumDifference(expected, actual)
                let staticDifference = maximumDifference(
                    staticEndpoint,
                    actual
                )
                // Independent compact Main-On insertions have a measured
                // terminal jitter. Exact equality is preferred; otherwise the
                // warm-up must be decisively closer to the Materialized
                // endpoint than to the directly-presented static Recipe.
                let followsMaterializedEndpoint =
                    insertionDifference.map { $0 <= 0.001 } == true
                    || {
                        guard let insertionDifference,
                              let staticDifference,
                              staticDifference > 0.01 else {
                            return false
                        }
                        return insertionDifference < staticDifference * 0.5
                    }()
                cells.append([
                    "usage": usage.displayName,
                    "requestedMain": requestedMain,
                    "insertionEndpoint": expected,
                    "directlyPresentedEndpoint": staticEndpoint,
                    "removalPreflight": actual,
                    "maximumDifferenceFromInsertion":
                        insertionDifference ?? NSNull(),
                    "maximumDifferenceFromDirectlyPresented":
                        staticDifference ?? NSNull(),
                    "passed":
                        expected.count == keys.count
                        && staticEndpoint.count == keys.count
                        && actual.count == keys.count
                        && followsMaterializedEndpoint,
                ])
            }
        }

        let failureCount = cells.filter {
            ($0["passed"] as? Bool) != true
        }.count
        return [
            "formatVersion": 1,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "operatingSystem":
                ProcessInfo.processInfo.operatingSystemVersionString,
            "shortSide": 48,
            "keys": keys,
            "cells": cells,
            "failureCount": failureCount,
            "passed": failureCount == 0,
        ]
    }
}
#endif
