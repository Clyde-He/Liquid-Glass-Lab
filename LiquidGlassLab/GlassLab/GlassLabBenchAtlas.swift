//
//  GlassLabBenchAtlas.swift
//  LiquidGlassLab
//
//  Bench: style-atlas capture and frozen-baseline acceptance. Orchestrates
//  the probe sweep that fills a GlassMaterialStyleAtlas (appearance × variant
//  × participation cells at bracketed short sides), persists it, drives the
//  frozen HUD acceptance panel, and quantifies the size-interpolation error
//  against live resolutions at unsampled sizes.
//

#if os(macOS)
import AppKit
import SwiftUI

extension GlassLabView {
    enum AtlasBenchError: LocalizedError {
        case overridesActive
        case contextRejected(String)
        case captureFailed(String)
        case atlasMissing

        var errorDescription: String? {
            switch self {
            case .overridesActive:
                "Disable Filter, Rim, and Color Matrix overrides first."
            case let .contextRejected(context):
                "The probe could not establish \(context)."
            case let .captureFailed(context):
                "The probe settled but the style capture failed at \(context)."
            case .atlasMissing:
                "No style atlas is loaded. Capture or load one first."
            }
        }
    }

    /// The probe short sides. They bracket the resolver's gates — the ≤64pt
    /// floor and the 64–160pt blur ramp — plus the reference 200pt and one
    /// larger size, so piecewise-linear interpolation never spans a gate.
    static var atlasProbeShortSides: [Double] { [48, 64, 96, 128, 160, 200, 320] }

    /// Unsampled sizes for the readback comparison, chosen between probe
    /// points including inside both gate regions.
    static var atlasReadbackShortSides: [Double] { [56, 80, 112, 144, 180, 260] }

    // MARK: - Page

    @ViewBuilder
    func benchAtlasSections(state labState: GlassLabState) -> some View {
        atlasCaptureSection(state: labState)
        hudDemoSection(state: labState)
        atlasReadbackSection()
    }

    @ViewBuilder
    private func atlasCaptureSection(state labState: GlassLabState) -> some View {
        Section("Style Atlas") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(
                        isCapturingAtlas ? "Capturing…" : "Capture Style Atlas"
                    ) {
                        captureStyleAtlas()
                    }
                    .disabled(isCapturingAtlas)
                    if isCapturingAtlas {
                        Button("Cancel") { atlasCaptureTask?.cancel() }
                    }
                    Button("Load Saved Atlas") { loadSavedAtlas() }
                        .disabled(isCapturingAtlas)
                }
                Text("Sweeps the test window through appearance × Regular/Clear × Main On/Off at short sides \(Self.atlasProbeShortSides.map { String(Int($0)) }.joined(separator: "/")) — \(8 * Self.atlasProbeShortSides.count) samples — then stamps the capture environment and saves the atlas to Application Support. The app must stay active; Main-On cells need real participation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let status = atlasStatus {
                Text(status)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }

            Text(atlasSummary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func hudDemoSection(state labState: GlassLabState) -> some View {
        Section("Frozen HUD (never key or main)") {
            Toggle(isOn: hudVisibleBinding) {
                LabRowLabel(
                    "Show HUD Panel",
                    description: "A borderless non-activating floating panel rendering a GlassMaterialEffectView frozen from the atlas with Main-On participation. It never becomes key or main; everything it shows beyond the flat material is the frozen restamp."
                )
            }
            .disabled(atlasDocument == nil && !hudPanelVisible)

            Picker("Appearance", selection: hudAppearanceBinding) {
                ForEach(GlassLabHUDPanelController.Appearance.allCases) { appearance in
                    Text(appearance.rawValue).tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            Picker("Material", selection: hudClearBinding) {
                Text("Regular").tag(false)
                Text("Clear").tag(true)
            }
            .pickerStyle(.segmented)

            labeledSlider("Glass Visibility", value: hudStrengthBinding, in: 0...1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ColorPicker(
                        "Tint",
                        selection: hudTintBinding,
                        supportsOpacity: true
                    )
                    Button("Lock Tint Hue") { lockTintForHUD() }
                        .disabled(
                            isCapturingAtlas || hudTintColor == nil
                                || atlasDocument == nil
                        )
                }
                Text("Zero opacity removes the tint. Lock Tint Hue captures the Main-On tint matrix for this color in all four appearance × material cells (capture-on-pick); until then the hue falls back to the live, hue-suppressed resolution.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            labeledSlider("Content Width", value: hudContentWidthBinding, in: 120...560)
            labeledSlider("Content Height", value: hudContentHeightBinding, in: 48...340)

            Text(hudStatusSummary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func atlasReadbackSection() -> some View {
        Section("Interpolation Readback") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(
                        isRunningAtlasReadback
                            ? "Comparing…" : "Run Interpolation Readback"
                    ) {
                        runAtlasInterpolationReadback()
                    }
                    .disabled(isRunningAtlasReadback || isCapturingAtlas || atlasDocument == nil)
                    if isRunningAtlasReadback {
                        Button("Cancel") { atlasReadbackTask?.cancel() }
                    }
                    if let report = atlasReadbackReport {
                        Button("Copy Report") { copyToPasteboard(report) }
                    }
                }
                Text("Re-drives the probe through the four Main-On cells at unsampled short sides \(Self.atlasReadbackShortSides.map { String(Int($0)) }.joined(separator: "/")), captures the live resolution, and diffs it channel by channel against the atlas interpolation at the same size. This quantifies the piecewise-linear residual the module documents as min(5%, 4/shortSide).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let report = atlasReadbackReport {
                ScrollView {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 260)
            }
        }
    }

    // MARK: - Readouts

    private var atlasSummary: String {
        guard let atlas = atlasDocument else {
            return "No atlas in memory. Saved file: "
                + ((try? Self.atlasStorageURL().path) ?? "unavailable")
        }
        var lines: [String] = []
        if let environment = atlas.environment {
            lines.append(
                "environment: schema \(environment.schemaVersion) · "
                    + "build \(environment.osBuild)"
            )
        } else {
            lines.append("environment: not stamped — freeze will refuse this atlas")
        }
        for main in [true, false] {
            for isLight in [true, false] {
                for isClear in [false, true] {
                    let cell = GlassMaterialStyleAtlas.Cell(
                        isLightAppearance: isLight,
                        isClear: isClear,
                        hasMainParticipation: main
                    )
                    let sides = atlas.sampleShortSides(for: cell)
                    lines.append(
                        (main ? "Main On " : "Main Off")
                            + " · " + (isLight ? "Light" : "Dark ")
                            + " · " + (isClear ? "Clear  " : "Regular")
                            + " · \(sides.count) sizes"
                            + (sides.isEmpty
                                ? ""
                                : " (\(sides.map { String(Int($0)) }.joined(separator: ", ")))")
                    )
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private var hudStatusSummary: String {
        guard let hud = hudPanelController, hudPanelVisible else {
            return "HUD hidden."
        }
        var lines: [String] = []
        lines.append(
            "freeze: " + (hud.lastFreezeSucceeded ? "installed" : "REFUSED")
                + " · strength available: "
                + (hud.strengthIsAvailable ? "yes" : "no")
        )
        lines.append(
            "window is key/main: " + (hud.windowIsMainOrKey ? "YES — INVALID" : "no")
                + String(format: " · window room: %.0fpt", hud.currentInset)
        )
        return lines.joined(separator: "\n")
    }

    // MARK: - HUD bindings

    private var hudVisibleBinding: Binding<Bool> {
        Binding { hudPanelVisible } set: { visible in
            hudPanelVisible = visible
            if visible {
                let controller = hudPanelController ?? GlassLabHUDPanelController()
                hudPanelController = controller
                controller.setAtlas(atlasDocument)
                controller.setAppearance(hudAppearance)
                controller.setClear(hudIsClear)
                controller.setStrength(hudStrength)
                controller.setTint(hudTintColor)
                controller.setContentSize(CGSize(
                    width: hudContentWidth,
                    height: hudContentHeight
                ))
                controller.show()
            } else {
                hudPanelController?.hide()
            }
        }
    }

    private var hudAppearanceBinding: Binding<GlassLabHUDPanelController.Appearance> {
        Binding { hudAppearance } set: { appearance in
            hudAppearance = appearance
            hudPanelController?.setAppearance(appearance)
        }
    }

    private var hudClearBinding: Binding<Bool> {
        Binding { hudIsClear } set: { isClear in
            hudIsClear = isClear
            hudPanelController?.setClear(isClear)
        }
    }

    private var hudStrengthBinding: Binding<Double> {
        Binding { hudStrength } set: { value in
            hudStrength = value
            hudPanelController?.setStrength(value)
        }
    }

    private var hudContentWidthBinding: Binding<Double> {
        Binding { hudContentWidth } set: { value in
            hudContentWidth = value
            pushHUDContentSize()
        }
    }

    private var hudContentHeightBinding: Binding<Double> {
        Binding { hudContentHeight } set: { value in
            hudContentHeight = value
            pushHUDContentSize()
        }
    }

    private func pushHUDContentSize() {
        hudPanelController?.setContentSize(CGSize(
            width: hudContentWidth,
            height: hudContentHeight
        ))
    }

    /// Zero opacity means "no tint", mirroring the lab's public-tint binding.
    private var hudTintBinding: Binding<Color> {
        Binding {
            hudTintColor.map(Color.init) ?? Color.white.opacity(0)
        } set: { color in
            let nsColor = NSColor(color)
            hudTintColor = nsColor.alphaComponent == 0 ? nil : nsColor
            hudPanelController?.setTint(hudTintColor)
        }
    }

    // MARK: - Persistence

    static func atlasStorageURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(
            "LiquidGlassLab",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("glass-style-atlas.json")
    }

    private func saveAtlasToDisk(_ atlas: GlassMaterialStyleAtlas) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = try Self.atlasStorageURL()
        try encoder.encode(atlas).write(to: url, options: .atomic)
        return url
    }

    static func loadAtlasFromDisk() throws -> GlassMaterialStyleAtlas {
        let data = try Data(contentsOf: atlasStorageURL())
        return try JSONDecoder().decode(GlassMaterialStyleAtlas.self, from: data)
    }

    func loadSavedAtlas() {
        do {
            let url = try Self.atlasStorageURL()
            let data = try Data(contentsOf: url)
            let atlas = try JSONDecoder().decode(
                GlassMaterialStyleAtlas.self,
                from: data
            )
            atlasDocument = atlas
            let current = GlassMaterialStyleAtlas.Environment.current(
                for: state.testWindow.liveWindow?.screen ?? NSScreen.main
            )
            let compatible = atlas.environment?.isCompatible(with: current) ?? false
            atlasStatus = "Loaded \(url.lastPathComponent)"
                + (compatible
                    ? " · environment compatible"
                    : " · ENVIRONMENT STALE — recapture before freezing")
            hudPanelController?.setAtlas(atlasDocument)
        } catch {
            atlasStatus = "Load failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Atlas capture

    func captureStyleAtlas() {
        guard !isCapturingAtlas else { return }
        guard !state.hasActiveOverrides else {
            atlasStatus = AtlasBenchError.overridesActive.errorDescription
            return
        }

        liveRefreshTask?.cancel()
        isCapturingAtlas = true
        atlasStatus = "Preparing atlas capture…"

        let restore = snapshotProbeContext()

        atlasCaptureTask = Task { @MainActor in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .userInitiated,
                    .idleSystemSleepDisabled,
                    .idleDisplaySleepDisabled,
                ],
                reason: "Capturing Liquid Glass style atlas"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                restoreProbeContext(restore)
                state.testWindow.sync(with: state)
                isCapturingAtlas = false
                atlasCaptureTask = nil
                scheduleLiveReadoutRefresh(refreshSchema: true)
            }

            do {
                let atlas = try await captureStyleAtlasDocument()
                atlasDocument = atlas
                let url = try saveAtlasToDisk(atlas)
                atlasStatus = "Captured "
                    + "\(8 * Self.atlasProbeShortSides.count) samples · "
                    + "saved to \(url.path)"
                hudPanelController?.setAtlas(atlas)
            } catch is CancellationError {
                atlasStatus = "Atlas capture cancelled; partial data discarded."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                atlasStatus = "Atlas capture failed: \(message)"
            }
        }
    }

    /// The full probe sweep: appearance × variant × participation at every
    /// probe short side, environment-stamped. The caller owns context
    /// save/restore; this only drives the sweep.
    func captureStyleAtlasDocument() async throws -> GlassMaterialStyleAtlas {
        configureAtlasProbeContext()
        var atlas = GlassMaterialStyleAtlas()
        let shortSides = Self.atlasProbeShortSides
        let total = 8 * shortSides.count
        var index = 0

        for requestedMain in [false, true] {
            for isLight in [true, false] {
                for isClear in [false, true] {
                    let cell = GlassMaterialStyleAtlas.Cell(
                        isLightAppearance: isLight,
                        isClear: isClear,
                        hasMainParticipation: requestedMain
                    )
                    state.testAppearance = isLight ? .light : .dark
                    state.variant = isClear ? 2 : 1
                    state.isTestWindowMain = requestedMain
                    for shortSide in shortSides {
                        index += 1
                        atlasStatus = "Capturing \(index)/\(total) · "
                            + Self.cellLabel(cell)
                            + " · \(Int(shortSide))pt"
                        state.glassHeight = shortSide
                        let sample = try await captureAtlasSample(
                            requestedMain: requestedMain,
                            context: Self.cellLabel(cell)
                                + " @ \(Int(shortSide))pt"
                        )
                        atlas.add(sample, for: cell)
                    }
                }
            }
        }

        atlas.environment = .current(
            for: state.testWindow.liveWindow?.screen
        )
        return atlas
    }

    /// One settled sample from the probe glass under the current lab state.
    /// Settling is two consecutive identical style captures — the sample is
    /// the exact payload the atlas stores, so equality is the right settle
    /// criterion, unlike a fixed sleep.
    private func captureAtlasSample(
        requestedMain: Bool,
        context: String
    ) async throws -> GlassMaterialStyleSample {
        for attempt in 1...5 {
            try Task.checkCancellation()
            try await waitUntilApplicationIsActive(
                progress: atlasStatus ?? "Atlas capture paused."
            )
            state.testWindow.sync(with: state)
            // A same-value variant write does not re-resolve the shader, and
            // a window appearance flip alone does not either — the first
            // atlas's Light cells captured the machine's dark resolution
            // while the window's effectiveAppearance dutifully reported
            // aqua. Only a fresh glass provably resolves every channel under
            // the current appearance, participation, and size.
            state.testWindow.rebuildGlass(with: state)
            guard let glass = state.testWindow.liveGlass else {
                try await Task.sleep(for: .milliseconds(180))
                continue
            }
            GlassLabTuning.applyRecipe(from: state, to: glass)
            // The rebuild inserts a fresh materialize; give it a beat to
            // settle into the long-lived Recipe before sampling stability.
            try await Task.sleep(for: .milliseconds(700))
            try Task.checkCancellation()
            guard NSApp.isActive,
                  state.testWindow.isActuallyMain == requestedMain,
                  !state.testWindow.isActuallyKey,
                  state.testAppearance.matchesName(
                    state.testWindow.effectiveAppearanceName ?? ""
                  ) else {
                if attempt < 5 { continue }
                throw AtlasBenchError.contextRejected(context)
            }
            var previous: GlassMaterialStyleSample?
            var stableCount = 0
            for _ in 0..<16 {
                try Task.checkCancellation()
                guard let current = GlassMaterialStyleSample.capture(
                    from: glass
                ) else {
                    previous = nil
                    stableCount = 0
                    try await Task.sleep(for: .milliseconds(300))
                    continue
                }
                if previous == current {
                    stableCount += 1
                    if stableCount >= 2 { return current }
                } else {
                    stableCount = 0
                }
                previous = current
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        throw AtlasBenchError.captureFailed(context)
    }

    // MARK: - Tint capture-on-pick

    /// Captures the Main-On tint matrix for the HUD's current color in all
    /// four appearance × material cells and folds them into the atlas. This
    /// is the product's capture-on-pick moment: the user chose the color in
    /// an active window, which is exactly the participation the matrix needs.
    func lockTintForHUD() {
        guard !isCapturingAtlas else { return }
        guard var atlas = atlasDocument else {
            atlasStatus = AtlasBenchError.atlasMissing.errorDescription
            return
        }
        guard let tint = hudTintColor else { return }
        guard !state.hasActiveOverrides else {
            atlasStatus = AtlasBenchError.overridesActive.errorDescription
            return
        }

        liveRefreshTask?.cancel()
        isCapturingAtlas = true
        atlasStatus = "Capturing tint matrices…"
        let restore = snapshotProbeContext()

        atlasCaptureTask = Task { @MainActor in
            defer {
                restoreProbeContext(restore)
                state.testWindow.sync(with: state)
                isCapturingAtlas = false
                atlasCaptureTask = nil
                scheduleLiveReadoutRefresh(refreshSchema: true)
            }
            do {
                try await captureTintMatrices(for: tint, into: &atlas)
                atlasDocument = atlas
                let url = try saveAtlasToDisk(atlas)
                atlasStatus = "Tint hue locked for all four Main-On cells · "
                    + "saved to \(url.lastPathComponent)"
                hudPanelController?.setAtlas(atlas)
            } catch is CancellationError {
                atlasStatus = "Tint capture cancelled."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                atlasStatus = "Tint capture failed: \(message)"
            }
        }
    }

    /// Captures the Main-On tint matrix for this color in all four
    /// appearance × material cells and folds them into the atlas. Shared by
    /// the interactive Lock Tint Hue button and the headless verification.
    func captureTintMatrices(
        for tint: NSColor,
        into atlas: inout GlassMaterialStyleAtlas
    ) async throws {
        configureAtlasProbeContext()
        state.glassHeight = 200
        state.isTestWindowMain = true
        state.tintColor = tint

        for isLight in [true, false] {
            for isClear in [false, true] {
                let cell = GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: true
                )
                atlasStatus = "Tint matrix · " + Self.cellLabel(cell)
                state.testAppearance = isLight ? .light : .dark
                state.variant = isClear ? 2 : 1
                let matrix = try await captureSettledTintMatrix(
                    context: Self.cellLabel(cell)
                )
                atlas.addTintMatrix(matrix, for: cell)
            }
        }
    }

    private func captureSettledTintMatrix(
        context: String
    ) async throws -> GlassMaterialStyleAtlas.TintMatrix {
        for attempt in 1...5 {
            try Task.checkCancellation()
            try await waitUntilApplicationIsActive(
                progress: atlasStatus ?? "Tint capture paused."
            )
            state.testWindow.sync(with: state)
            // Same context discipline as the style sweep: only a fresh glass
            // provably resolves the tint matrix under the requested
            // appearance rather than the machine's current one.
            state.testWindow.rebuildGlass(with: state)
            guard let glass = state.testWindow.liveGlass else {
                try await Task.sleep(for: .milliseconds(180))
                continue
            }
            GlassLabTuning.applyRecipe(from: state, to: glass)
            try await Task.sleep(for: .milliseconds(700))
            try Task.checkCancellation()
            guard NSApp.isActive,
                  state.testWindow.isActuallyMain,
                  !state.testWindow.isActuallyKey,
                  state.testAppearance.matchesName(
                    state.testWindow.effectiveAppearanceName ?? ""
                  ) else {
                if attempt < 5 { continue }
                throw AtlasBenchError.contextRejected(context)
            }
            var previous: GlassMaterialStyleAtlas.TintMatrix?
            for _ in 0..<12 {
                try Task.checkCancellation()
                guard let current = GlassMaterialStyleAtlas.captureTintMatrix(
                    from: glass
                ) else {
                    previous = nil
                    try await Task.sleep(for: .milliseconds(160))
                    continue
                }
                if let previous, previous == current {
                    return current
                }
                previous = current
                try await Task.sleep(for: .milliseconds(160))
            }
        }
        throw AtlasBenchError.captureFailed(context)
    }

    // MARK: - Interpolation readback

    func runAtlasInterpolationReadback() {
        guard !isRunningAtlasReadback, !isCapturingAtlas else { return }
        guard let atlas = atlasDocument else {
            atlasStatus = AtlasBenchError.atlasMissing.errorDescription
            return
        }
        guard !state.hasActiveOverrides else {
            atlasStatus = AtlasBenchError.overridesActive.errorDescription
            return
        }

        liveRefreshTask?.cancel()
        isRunningAtlasReadback = true
        atlasReadbackReport = nil
        let restore = snapshotProbeContext()

        atlasReadbackTask = Task { @MainActor in
            defer {
                restoreProbeContext(restore)
                state.testWindow.sync(with: state)
                isRunningAtlasReadback = false
                atlasReadbackTask = nil
                scheduleLiveReadoutRefresh(refreshSchema: true)
            }
            do {
                configureAtlasProbeContext()
                state.isTestWindowMain = true

                var lines: [String] = []
                var worst: (Double, String) = (0, "none")

                for isLight in [true, false] {
                    for isClear in [false, true] {
                        let cell = GlassMaterialStyleAtlas.Cell(
                            isLightAppearance: isLight,
                            isClear: isClear,
                            hasMainParticipation: true
                        )
                        state.testAppearance = isLight ? .light : .dark
                        state.variant = isClear ? 2 : 1
                        for shortSide in Self.atlasReadbackShortSides {
                            atlasStatus = "Readback · " + Self.cellLabel(cell)
                                + " · \(Int(shortSide))pt"
                            state.glassHeight = shortSide
                            let live = try await captureAtlasSample(
                                requestedMain: true,
                                context: Self.cellLabel(cell)
                                    + " @ \(Int(shortSide))pt"
                            )
                            guard let interpolated = atlas.sample(
                                for: cell,
                                at: shortSide
                            ) else {
                                lines.append(
                                    "\(Self.cellLabel(cell)) @ \(Int(shortSide)): NO ATLAS SAMPLE"
                                )
                                continue
                            }
                            let diff = Self.compareSamples(
                                live: live,
                                interpolated: interpolated
                            )
                            lines.append(
                                String(
                                    format: "%@ @ %3dpt · max rel %.3f%% (%@)",
                                    Self.cellLabel(cell),
                                    Int(shortSide),
                                    diff.maxRelative * 100,
                                    diff.worstKey
                                )
                            )
                            for offender in diff.offenders {
                                lines.append("    " + offender)
                            }
                            if diff.maxRelative > worst.0 {
                                worst = (
                                    diff.maxRelative,
                                    "\(diff.worstKey) · \(Self.cellLabel(cell)) @ \(Int(shortSide))pt"
                                )
                            }
                        }
                    }
                }

                lines.append("")
                lines.append(String(
                    format: "worst channel: %@ · %.3f%% (documented bound: min(5%%, 4/shortSide))",
                    worst.1,
                    worst.0 * 100
                ))
                atlasReadbackReport = lines.joined(separator: "\n")
                atlasStatus = "Readback complete."
            } catch is CancellationError {
                atlasStatus = "Readback cancelled."
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                atlasStatus = "Readback failed: \(message)"
            }
        }
    }

    private struct SampleDiff {
        var maxRelative: Double
        var worstKey: String
        var offenders: [String]
    }

    /// Channel-by-channel comparison. Relative error uses the live magnitude
    /// with a 0.01 floor so near-zero channels do not report infinite ratios.
    /// Offenders list channels beyond 1% so the report stays readable.
    private static func compareSamples(
        live: GlassMaterialStyleSample,
        interpolated: GlassMaterialStyleSample
    ) -> SampleDiff {
        var maxRelative = 0.0
        var worstKey = "none"
        var offenders: [String] = []

        func note(_ key: String, _ liveValue: Double, _ atlasValue: Double) {
            let magnitude = max(abs(liveValue), abs(atlasValue), 0.01)
            let relative = abs(liveValue - atlasValue) / magnitude
            if relative > maxRelative {
                maxRelative = relative
                worstKey = key
            }
            if relative > 0.01 {
                offenders.append(String(
                    format: "%@: live %.4f vs atlas %.4f (%.2f%%)",
                    key, liveValue, atlasValue, relative * 100
                ))
            }
        }

        for (key, liveValue) in live.numeric {
            guard let atlasValue = interpolated.numeric[key] else {
                offenders.append("\(key): missing from atlas sample")
                continue
            }
            note(key, liveValue, atlasValue)
        }
        for (key, liveValue) in live.colors {
            guard let atlasValue = interpolated.colors[key] else {
                offenders.append("\(key): color missing from atlas sample")
                continue
            }
            note("\(key).r", liveValue.red, atlasValue.red)
            note("\(key).g", liveValue.green, atlasValue.green)
            note("\(key).b", liveValue.blue, atlasValue.blue)
            note("\(key).a", liveValue.alpha, atlasValue.alpha)
        }
        for (key, liveValue) in live.points {
            guard let atlasValue = interpolated.points[key] else {
                offenders.append("\(key): point missing from atlas sample")
                continue
            }
            note("\(key).x", liveValue.x, atlasValue.x)
            note("\(key).y", liveValue.y, atlasValue.y)
        }
        if live.nilKeys != interpolated.nilKeys {
            let delta = live.nilKeys.symmetricDifference(interpolated.nilKeys)
            offenders.append(
                "nilKeys differ: \(delta.sorted().joined(separator: ", "))"
            )
        }
        note("marginWidth", live.marginWidth, interpolated.marginWidth)
        note("outputMinimum", live.outputMinimum, interpolated.outputMinimum)
        note("outputMaximum", live.outputMaximum, interpolated.outputMaximum)

        if live.matrices.count == interpolated.matrices.count {
            for (slot, pair) in zip(live.matrices, interpolated.matrices)
                .enumerated() {
                for (index, values) in zip(pair.0.matrix, pair.1.matrix)
                    .enumerated() {
                    note(
                        "matrix\(slot)[\(index)]",
                        Double(values.0),
                        Double(values.1)
                    )
                }
            }
        } else {
            offenders.append("matrix slot count mismatch")
        }

        if live.rims.count == interpolated.rims.count {
            for (slot, pair) in zip(live.rims, interpolated.rims).enumerated() {
                for (key, liveValue) in pair.0.values {
                    guard let atlasValue = pair.1.values[key] else {
                        offenders.append("rim\(slot).\(key): missing from atlas")
                        continue
                    }
                    note("rim\(slot).\(key)", liveValue, atlasValue)
                }
            }
        } else {
            offenders.append("rim slot count mismatch")
        }

        return SampleDiff(
            maxRelative: maxRelative,
            worstKey: worstKey,
            offenders: offenders
        )
    }

    // MARK: - Headless end-to-end verification

    /// The automatable core of the frozen-baseline smoke test: capture a full
    /// atlas, round-trip it through Codable, freeze a real never-key-never-
    /// main HUD panel from the decoded copy, then walk appearance × material
    /// × size × G and assert — at the model layer — that the frozen restamp
    /// stays available, tracks the atlas endpoints at G = 1, keeps the face
    /// opacity monotonic in G, and holds the sampled render bounds. Visual
    /// acceptance stays with the author; this catches every wiring failure
    /// that does not need eyes.
    @MainActor
    func performStyleAtlasVerification() async throws -> [String: Any] {
        let restore = snapshotProbeContext()
        defer {
            restoreProbeContext(restore)
            state.testWindow.sync(with: state)
        }

        var steps: [[String: Any]] = []
        func step(_ name: String, _ passed: Bool, _ detail: String) {
            steps.append(["name": name, "passed": passed, "detail": detail])
        }

        // Reuse a compatible saved atlas so iterating on the acceptance
        // half does not pay for a fresh 56-sample sweep every run; delete
        // the saved file to force a clean capture.
        let atlas: GlassMaterialStyleAtlas
        if let saved = try? Self.loadAtlasFromDisk(),
           saved.environment?.isCompatible(
            with: .current(for: state.testWindow.liveWindow?.screen)
           ) == true {
            atlas = saved
            step("atlas-source", true, "reused saved atlas")
        } else {
            atlas = try await captureStyleAtlasDocument()
            _ = try? saveAtlasToDisk(atlas)
            step("atlas-source", true, "fresh capture")
        }

        let data = try JSONEncoder().encode(atlas)
        let decoded = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: data
        )
        var decodedCellsOK = true
        for main in [true, false] {
            for isLight in [true, false] {
                for isClear in [true, false] {
                    let cell = GlassMaterialStyleAtlas.Cell(
                        isLightAppearance: isLight,
                        isClear: isClear,
                        hasMainParticipation: main
                    )
                    if !decoded.cellMatchesSupportedTopology(cell) {
                        decodedCellsOK = false
                    }
                }
            }
        }
        step(
            "codable-round-trip",
            decodedCellsOK,
            "all 8 cells re-validate after decode"
        )

        // Informational: the sampled margin per Main-On cell and size, so a
        // failed margin assertion can be read against what capture stored.
        for isLight in [true, false] {
            for isClear in [false, true] {
                let cell = GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: true
                )
                let margins = Self.atlasProbeShortSides.compactMap {
                    decoded.sample(for: cell, at: $0).map { sample in
                        String(format: "%.1f", sample.marginWidth)
                    }
                }
                step(
                    "info-margins \(Self.cellLabel(cell))",
                    true,
                    margins.joined(separator: ", ")
                )
            }
        }

        let hud = GlassLabHUDPanelController()
        defer { hud.tearDown() }
        // Show unfrozen first: the system-resolved margin on this
        // never-key-never-main panel is the reference for who wins later.
        hud.show()
        try await Task.sleep(for: .milliseconds(1200))
        if let glass = hud.glassView {
            let systemMargin = GlassMaterialAccess.marginWidth(under: glass)
            step(
                "info-system-margin-on-hud",
                true,
                String(format: "%.3f", systemMargin ?? .nan)
            )
        }
        hud.setAtlas(decoded)
        // Materialize insertion needs about a second to settle into the
        // long-lived Recipe; poking earlier races the system's own writes.
        try await Task.sleep(for: .milliseconds(1000))

        step("freeze-installed", hud.lastFreezeSucceeded, "freeze(atlas:)")
        step(
            "never-key-or-main",
            !hud.windowIsMainOrKey,
            "non-activating panel participation"
        )

        let contentSizes = [
            CGSize(width: 150, height: 56),
            CGSize(width: 320, height: 120),
            CGSize(width: 520, height: 280),
        ]
        for appearance in [
            GlassLabHUDPanelController.Appearance.light, .dark,
        ] {
            for isClear in [false, true] {
                hud.setAppearance(appearance)
                hud.setClear(isClear)
                try await Task.sleep(for: .milliseconds(400))
                let cell = GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: appearance == .light,
                    isClear: isClear,
                    hasMainParticipation: true
                )
                let cellName = Self.cellLabel(cell)

                for size in contentSizes {
                    hud.setContentSize(size)
                    let shortSide = min(size.width, size.height)
                    let context = "\(cellName) @ \(Int(shortSide))pt"
                    guard let glass = hud.glassView,
                          let expected = decoded.sample(
                            for: cell,
                            at: shortSide
                          ) else {
                        step("frozen-context \(context)", false, "no glass or sample")
                        continue
                    }
                    let expectedFace =
                        expected.numeric["inputFaceOpacity"] ?? .nan

                    // A context change (resize, appearance, variant) is
                    // eventually consistent by design: the system re-derives
                    // after our restamp and the trailing re-apply answers one
                    // beat later. Poll passively — no nudging, a static HUD
                    // gets no nudges either — and record time-to-converge.
                    hud.setStrength(1)
                    var convergedAfter: Int?
                    for elapsed in stride(from: 200, through: 5000, by: 200) {
                        try await Task.sleep(for: .milliseconds(200))
                        let face = Self.appliedFaceOpacity(on: glass)
                        let liveMargin = GlassMaterialAccess.marginWidth(
                            under: glass
                        )
                        if let face, abs(face - expectedFace) < 0.02,
                           let liveMargin,
                           abs(liveMargin - expected.marginWidth) < 0.5 {
                            convergedAfter = elapsed
                            break
                        }
                    }
                    step(
                        "context-converges \(context)",
                        convergedAfter != nil,
                        convergedAfter.map { "converged after \($0)ms" }
                            ?? "no convergence within 5s"
                    )

                    let availableAtOne = glass.materialStrength.isAvailable
                    let faceAtOne = Self.appliedFaceOpacity(on: glass)
                    let margin = GlassMaterialAccess.marginWidth(under: glass)

                    // G writes are transiently contestable in the same churn
                    // windows as the margin — poll each target until the face
                    // lands, which is the actual contract: a scrub's every
                    // frame re-applies, so only eventual take-up is promised.
                    func settledFace(at g: Double) async throws -> Double? {
                        hud.setStrength(g)
                        let target = g * expectedFace
                        var last: Double?
                        for _ in 0..<10 {
                            try await Task.sleep(for: .milliseconds(150))
                            last = Self.appliedFaceOpacity(on: glass)
                            if let last, abs(last - target) < 0.02 {
                                return last
                            }
                        }
                        return last
                    }
                    let faceAtHalf = try await settledFace(at: 0.5)
                    let faceAtZero = try await settledFace(at: 0)
                    hud.setStrength(1)

                    let endpointOK = faceAtOne.map {
                        abs($0 - expectedFace) < 0.02
                    } ?? false
                    let monotonicOK: Bool
                    if let one = faceAtOne, let half = faceAtHalf,
                       let zero = faceAtZero {
                        monotonicOK = zero <= half + 0.001
                            && half <= one + 0.001
                            && one - zero > 0.05
                    } else {
                        monotonicOK = false
                    }
                    let marginOK = margin.map {
                        abs($0 - expected.marginWidth) < 0.5
                    } ?? false

                    // When the restamped margin does not read back, probe who
                    // the final writer is: write directly, then sample a
                    // timeline. "Lands then reverts once", "keeps reverting",
                    // and "never lands" are three different bugs.
                    var marginForensics = ""
                    if !marginOK {
                        GlassMaterialAccess.setMarginWidth(
                            expected.marginWidth,
                            under: glass
                        )
                        var timeline: [String] = [String(
                            format: "0ms %.2f",
                            GlassMaterialAccess.marginWidth(under: glass) ?? .nan
                        )]
                        for delay in [100, 250, 500, 1000, 2000] {
                            try await Task.sleep(for: .milliseconds(delay))
                            timeline.append(String(
                                format: "+%dms %.2f",
                                delay,
                                GlassMaterialAccess.marginWidth(
                                    under: glass
                                ) ?? .nan
                            ))
                        }
                        marginForensics = " · direct write timeline: "
                            + timeline.joined(separator: ", ")

                        // Discriminate the fight: does the live rim still
                        // match the frozen payload (if not, every apply
                        // replaces it and re-provokes the reaction), and
                        // does one more apply zero the margin the direct
                        // write just parked?
                        var rimMatches = false
                        if let rimLayer = GlassMaterialAccess.rimLayers(
                            under: glass
                        ).first, let rim = expected.rims.first {
                            var rimColors: [String: NSColor] = [:]
                            for (key, color) in rim.colors {
                                rimColors[key] = color.nsColor
                            }
                            rimMatches = GlassMaterialAccess.rimPayloadMatches(
                                values: rim.values,
                                colors: rimColors,
                                on: rimLayer
                            )
                        }
                        hud.setStrength(0.99)
                        try await Task.sleep(for: .milliseconds(60))
                        let afterReapplySoon = GlassMaterialAccess.marginWidth(
                            under: glass
                        )
                        try await Task.sleep(for: .milliseconds(340))
                        let afterReapplyLate = GlassMaterialAccess.marginWidth(
                            under: glass
                        )
                        hud.setStrength(1)
                        marginForensics += String(
                            format: " · rimMatches %@ · post-reapply +60ms %.2f, +400ms %.2f",
                            rimMatches ? "yes" : "NO",
                            afterReapplySoon ?? .nan,
                            afterReapplyLate ?? .nan
                        )
                    }

                    let output = GlassMaterialAccess.outputBounds(under: glass)
                    let outputOK = output.map {
                        abs($0.maximum - expected.outputMaximum) < 0.5
                    } ?? false

                    step(
                        "frozen-available \(context)",
                        availableAtOne,
                        "isAvailable under frozen atlas"
                    )
                    step(
                        "endpoint-tracks-atlas \(context)",
                        endpointOK,
                        String(
                            format: "faceOpacity %.4f vs atlas %.4f",
                            faceAtOne ?? .nan,
                            expectedFace
                        )
                    )
                    step(
                        "g-monotonic \(context)",
                        monotonicOK,
                        String(
                            format: "g0 %.4f · g0.5 %.4f · g1 %.4f",
                            faceAtZero ?? .nan,
                            faceAtHalf ?? .nan,
                            faceAtOne ?? .nan
                        )
                    )
                    step(
                        "margin-tracks-atlas \(context)",
                        marginOK,
                        String(
                            format: "marginWidth %.2f vs atlas %.2f",
                            margin ?? .nan,
                            expected.marginWidth
                        ) + marginForensics
                    )
                    step(
                        "output-tracks-atlas \(context)",
                        outputOK,
                        String(
                            format: "outputMax %.2f vs atlas %.2f",
                            output?.maximum ?? .nan,
                            expected.outputMaximum
                        )
                    )

                    // At G = 1 the written colors and grade matrices equal
                    // the sample exactly — the appearance axis lives largely
                    // here, so numeric checks alone would miss a restamp
                    // that reverts only colors and grades (measured on an
                    // appearance switch).
                    hud.setStrength(1)
                    var colorsOK = false
                    for _ in 0..<10 {
                        try await Task.sleep(for: .milliseconds(200))
                        guard let target =
                            GlassMaterialAccess.glassBackgroundTarget(
                                under: glass
                            ) else { continue }
                        let colors = GlassMaterialAccess.readTypedInputs(
                            from: target
                        ).colors
                        colorsOK = expected.colors.allSatisfy { key, value in
                            colors[key].map {
                                GlassMaterialAccess.colorsMatch(
                                    $0,
                                    value.nsColor
                                )
                            } ?? false
                        }
                        if colorsOK { break }
                    }
                    step(
                        "colors-track-atlas \(context)",
                        colorsOK,
                        "\(expected.colors.count) color inputs vs atlas at G=1"
                    )

                    let gradeLayers = GlassMaterialAccess.untintedMatrixLayers(
                        under: glass
                    )
                    var gradesOK = gradeLayers.count == expected.matrices.count
                    if gradesOK {
                        for (layer, slot) in zip(
                            gradeLayers,
                            expected.matrices
                        ) {
                            guard let current = GlassMaterialAccess.colorMatrix(
                                on: layer
                            ), current.count == slot.matrix.count,
                                zip(current, slot.matrix).allSatisfy({
                                    abs($0 - $1) < 1e-3
                                })
                            else {
                                gradesOK = false
                                break
                            }
                        }
                    }
                    step(
                        "grades-track-atlas \(context)",
                        gradesOK,
                        "both untinted matrices vs atlas at G=1"
                    )
                }
            }
        }

        // Diagnostic: forced-Light presentation probe. The model layer can
        // hold every frozen Light value while the eye still sees the dark
        // material — either an animation is pinning the presentation, or the
        // visible difference lives outside the captured tree. Dump the color
        // inputs from BOTH trees plus every animation on the subtree.
        hud.setAppearance(.light)
        hud.setClear(false)
        hud.setContentSize(CGSize(width: 320, height: 120))
        hud.setStrength(1)
        try await Task.sleep(for: .milliseconds(1500))
        if let glass = hud.glassView, let layer = glass.layer {
            CATransaction.flush()
            let model = GlassLabTuning.capturePassAuditSnapshot(from: layer)
            let presentation = GlassLabTuning.capturePassAuditSnapshot(
                from: layer.presentation()
            )
            func colorDump(
                _ snapshot: GlassLabTuning.PassAuditSnapshot?
            ) -> String {
                guard let snapshot else { return "nil snapshot" }
                var lines: [String] = []
                for (id, pass) in snapshot.passes.sorted(by: { $0.key < $1.key })
                where pass.name?.contains("glassBackground") == true
                    || pass.objectClass.contains("Backdrop") {
                    for (key, property) in pass.properties.sorted(
                        by: { $0.key < $1.key }
                    ) where key.lowercased().contains("color") {
                        lines.append(
                            "\(id).\(key)=\(property.value ?? property.state)"
                        )
                    }
                }
                return lines.joined(separator: " · ")
            }
            step("info-light-model-colors", true, colorDump(model))
            step(
                "info-light-presentation-colors",
                true,
                colorDump(presentation)
            )

            var animationLines: [String] = []
            func walkAnimations(_ current: CALayer, path: String) {
                if let keys = current.animationKeys(), !keys.isEmpty {
                    animationLines.append(
                        "\(path)[\(String(describing: type(of: current)))]: "
                            + keys.joined(separator: ",")
                    )
                }
                for (index, child) in (current.sublayers ?? []).enumerated() {
                    walkAnimations(child, path: path + ".\(index)")
                }
            }
            walkAnimations(layer, path: "root")
            step(
                "info-light-animations",
                true,
                animationLines.isEmpty
                    ? "no animations on the subtree"
                    : animationLines.joined(separator: " · ")
            )

            let cell = GlassMaterialStyleAtlas.Cell(
                isLightAppearance: true,
                isClear: false,
                hasMainParticipation: true
            )
            if let sample = decoded.sample(for: cell, at: 120) {
                let colors = sample.colors.sorted(by: { $0.key < $1.key })
                    .map { key, value in
                        String(
                            format: "%@=(%.3f %.3f %.3f %.3f)",
                            key, value.red, value.green, value.blue,
                            value.alpha
                        )
                    }
                step(
                    "info-light-atlas-colors",
                    true,
                    colors.joined(separator: " · ")
                )
            }
        }

        // Continuous-drag simulation — the interactive failure mode the
        // single-resize contexts missed: a burst of rapid size changes ends
        // with the system's late restamp winning, and on Clear cells the
        // sampled margin equals the system's (both 0), so a margin-only
        // sentinel never heals it. Burst-resize each variant, then require
        // passive convergence of face, margin, and the rim payload.
        for isClear in [true, false] {
            hud.setAppearance(.dark)
            hud.setClear(isClear)
            try await Task.sleep(for: .milliseconds(600))
            let cell = GlassMaterialStyleAtlas.Cell(
                isLightAppearance: false,
                isClear: isClear,
                hasMainParticipation: true
            )
            hud.setStrength(0.6)
            for stepIndex in 0...10 {
                hud.setContentSize(CGSize(
                    width: 320,
                    height: 200 + Double(stepIndex) * 6
                ))
                try await Task.sleep(for: .milliseconds(30))
            }
            let shortSide = 260.0
            let expected = decoded.sample(for: cell, at: shortSide)
            let expectedFace = expected?.numeric["inputFaceOpacity"] ?? .nan
            var convergedAfter: Int?
            if let glass = hud.glassView, let expected {
                for elapsed in stride(from: 200, through: 5000, by: 200) {
                    try await Task.sleep(for: .milliseconds(200))
                    let face = Self.appliedFaceOpacity(on: glass)
                    let margin = GlassMaterialAccess.marginWidth(under: glass)
                    var rimHolds = false
                    if let rimLayer = GlassMaterialAccess.rimLayers(
                        under: glass
                    ).first, let rim = expected.rims.first {
                        var rimColors: [String: NSColor] = [:]
                        for (key, color) in rim.colors {
                            rimColors[key] = color.nsColor
                        }
                        rimHolds = GlassMaterialAccess.rimPayloadMatches(
                            values: rim.values,
                            colors: rimColors,
                            on: rimLayer
                        )
                    }
                    if let face, abs(face - 0.6 * expectedFace) < 0.02,
                       let margin,
                       abs(margin - expected.marginWidth) < 0.5,
                       rimHolds {
                        convergedAfter = elapsed
                        break
                    }
                }
            }
            step(
                "drag-burst-heals MainOn·Dark·\(isClear ? "Clear" : "Regular")",
                convergedAfter != nil,
                convergedAfter.map { "converged after \($0)ms" }
                    ?? "no convergence within 5s after drag burst"
            )
            hud.setStrength(1)
        }

        // Tint capture-on-pick — assert the whole pipeline on the HUD: the
        // tint branch exists on a never-main window at all, the captured
        // Main-context hue is installed rather than the live suppressed one,
        // and coefficient 18 carries sourceAlpha × G².
        let tintColor = NSColor(srgbRed: 1.0, green: 0.45, blue: 0.35, alpha: 0.6)
        var tintedAtlas = decoded
        try await captureTintMatrices(for: tintColor, into: &tintedAtlas)
        hud.setAtlas(tintedAtlas)
        hud.setAppearance(.dark)
        hud.setClear(false)
        hud.setContentSize(CGSize(width: 320, height: 120))
        hud.setTint(tintColor)
        hud.setStrength(1)
        try await Task.sleep(for: .milliseconds(1000))
        if let glass = hud.glassView {
            let cell = GlassMaterialStyleAtlas.Cell(
                isLightAppearance: false,
                isClear: false,
                hasMainParticipation: true
            )
            let expectedHue = tintedAtlas.tintMatrix(
                for: cell,
                matching: tintColor
            )
            var layerExists = false
            var hueOK = false
            var alphaAtOne = Double.nan
            for _ in 0..<15 {
                try await Task.sleep(for: .milliseconds(200))
                guard let tintLayer = GlassMaterialAccess.tintMatrixLayer(
                    under: glass
                ) else { continue }
                layerExists = true
                guard let current = GlassMaterialAccess.colorMatrix(
                    on: tintLayer
                ), current.count == 20 else { continue }
                alphaAtOne = Double(current[18])
                if let expectedHue, expectedHue.count == 20 {
                    hueOK = (0..<20).filter { $0 != 18 }.allSatisfy {
                        abs(current[$0] - expectedHue[$0]) < 1e-3
                    }
                }
                if hueOK, abs(alphaAtOne - 0.6) < 0.02 { break }
            }
            step(
                "tint-layer-exists-on-hud",
                layerExists,
                "tint matrix branch present on the never-main panel"
            )
            step(
                "tint-hue-tracks-capture",
                hueOK,
                "19 hue coefficients vs the captured Main-context matrix"
            )
            step(
                "tint-alpha-at-g1",
                abs(alphaAtOne - 0.6) < 0.02,
                String(format: "matrix[18] %.4f vs sourceAlpha 0.6", alphaAtOne)
            )

            hud.setStrength(0.5)
            var alphaAtHalf = Double.nan
            for _ in 0..<15 {
                try await Task.sleep(for: .milliseconds(200))
                if let tintLayer = GlassMaterialAccess.tintMatrixLayer(
                    under: glass
                ), let current = GlassMaterialAccess.colorMatrix(
                    on: tintLayer
                ), current.count == 20 {
                    alphaAtHalf = Double(current[18])
                    if abs(alphaAtHalf - 0.15) < 0.02 { break }
                }
            }
            step(
                "tint-alpha-at-g05",
                abs(alphaAtHalf - 0.15) < 0.02,
                String(
                    format: "matrix[18] %.4f vs 0.6 × 0.5² = 0.15",
                    alphaAtHalf
                )
            )
            hud.setTint(nil)
            hud.setStrength(1)
            try await Task.sleep(for: .milliseconds(400))
        }

        // App deactivate/reactivate — the P2-sensitive transition. The HUD is
        // never key or main, so the *only* event that flips its resolved
        // participation is application activation; the frozen style must
        // survive both directions. The effect view observes the app
        // notifications, so this asserts the whole chain: system restamp →
        // observed → frozen re-apply wins as final writer.
        if let glass = hud.glassView {
            let cell = GlassMaterialStyleAtlas.Cell(
                isLightAppearance: false,
                isClear: true,
                hasMainParticipation: true
            )
            let shortSide = min(520.0, 280.0)
            let expectedFace = decoded.sample(for: cell, at: shortSide)?
                .numeric["inputFaceOpacity"] ?? .nan
            hud.setStrength(0.7)

            func faceHolds() async throws -> (Bool, Double) {
                var last = Double.nan
                for _ in 0..<15 {
                    try await Task.sleep(for: .milliseconds(200))
                    if let face = Self.appliedFaceOpacity(on: glass) {
                        last = face
                        if abs(face - 0.7 * expectedFace) < 0.02 {
                            return (true, face)
                        }
                    }
                }
                return (false, last)
            }

            NSApp.deactivate()
            try await Task.sleep(for: .milliseconds(800))
            let whileInactive = try await faceHolds()
            step(
                "frozen-survives-deactivate",
                whileInactive.0,
                String(
                    format: "face %.4f vs expected %.4f while inactive",
                    whileInactive.1,
                    0.7 * expectedFace
                )
            )

            NSApplication.shared.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(800))
            let afterReactivate = try await faceHolds()
            step(
                "frozen-survives-reactivate",
                afterReactivate.0,
                String(
                    format: "face %.4f vs expected %.4f after reactivation",
                    afterReactivate.1,
                    0.7 * expectedFace
                )
            )
            hud.setStrength(1)
        }

        let failures = steps.filter { ($0["passed"] as? Bool) != true }
        return [
            "formatVersion": 1,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "operatingSystem":
                ProcessInfo.processInfo.operatingSystemVersionString,
            "probeShortSides": Self.atlasProbeShortSides,
            "steps": steps,
            "passed": failures.isEmpty,
            "failureCount": failures.count,
        ]
    }

    private static func appliedFaceOpacity(
        on glass: NSGlassEffectView
    ) -> Double? {
        guard let target = GlassMaterialAccess.glassBackgroundTarget(
            under: glass
        ) else { return nil }
        return GlassMaterialAccess.readTypedInputs(from: target)
            .numeric["inputFaceOpacity"]
    }

    // MARK: - Probe context plumbing

    struct AtlasProbeRestoreContext {
        var rendererMode: GlassLabRendererMode
        var recipePage: RecipePage
        var variant: Int
        var subvariant: String
        var isSubdued: Bool
        var hasScrim: Bool
        var hasReducedTintOpacity: Bool
        var adaptiveAppearance: Int
        var tintColor: NSColor?
        var glassWidth: Double
        var glassHeight: Double
        var cornerRadius: Double
        var hostType: GlassLabWindowHostType
        var appearance: GlassLabTestAppearance
        var backdrop: GlassLabBackdropMode
        var isMain: Bool
        var padding: Double
        var isVisible: Bool
    }

    private func snapshotProbeContext() -> AtlasProbeRestoreContext {
        AtlasProbeRestoreContext(
            rendererMode: state.rendererMode,
            recipePage: selectedRecipePage,
            variant: state.variant,
            subvariant: state.subvariant,
            isSubdued: state.isSubdued,
            hasScrim: state.hasScrim,
            hasReducedTintOpacity: state.hasReducedTintOpacity,
            adaptiveAppearance: state.adaptiveAppearance,
            tintColor: state.tintColor,
            glassWidth: state.glassWidth,
            glassHeight: state.glassHeight,
            cornerRadius: state.cornerRadius,
            hostType: state.windowHostType,
            appearance: state.testAppearance,
            backdrop: state.testBackdrop,
            isMain: state.isTestWindowMain,
            padding: state.windowPadding,
            isVisible: state.isTestWindowVisible
        )
    }

    private func restoreProbeContext(_ context: AtlasProbeRestoreContext) {
        state.rendererMode = context.rendererMode
        selectedRecipePage = context.recipePage
        state.variant = context.variant
        state.subvariant = context.subvariant
        state.isSubdued = context.isSubdued
        state.hasScrim = context.hasScrim
        state.hasReducedTintOpacity = context.hasReducedTintOpacity
        state.adaptiveAppearance = context.adaptiveAppearance
        state.tintColor = context.tintColor
        state.glassWidth = context.glassWidth
        state.glassHeight = context.glassHeight
        state.cornerRadius = context.cornerRadius
        state.windowHostType = context.hostType
        state.testAppearance = context.appearance
        state.testBackdrop = context.backdrop
        state.isTestWindowMain = context.isMain
        state.windowPadding = context.padding
        state.isTestWindowVisible = context.isVisible
    }

    /// The fixed probe context: Recipe renderer in the transparent Panel host
    /// with a pristine recipe, ambient backdrop, and the maximum window
    /// margin so no sampled size clips its outer passes.
    private func configureAtlasProbeContext() {
        state.rendererMode = .recipe
        selectedRecipePage = .general
        state.isTestWindowVisible = true
        state.windowHostType = .panel
        state.testBackdrop = .ambient
        state.isSubdued = false
        state.hasScrim = false
        state.hasReducedTintOpacity = false
        state.subvariant = ""
        state.adaptiveAppearance = 2
        state.tintColor = nil
        state.cornerRadius = 16
        state.windowPadding = 120
        state.glassWidth = 480
    }

    private static func cellLabel(_ cell: GlassMaterialStyleAtlas.Cell) -> String {
        (cell.hasMainParticipation ? "MainOn" : "MainOff")
            + "·" + (cell.isLightAppearance ? "Light" : "Dark")
            + "·" + (cell.isClear ? "Clear" : "Regular")
    }
}
#endif
