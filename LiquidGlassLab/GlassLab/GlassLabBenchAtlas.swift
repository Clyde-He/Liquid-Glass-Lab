//
//  GlassLabBenchAtlas.swift
//  LiquidGlassLab
//
//  Bench: runtime Provider, frozen HUD acceptance, and Catalog readback.
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
                "No style atlas is loaded. Load the Provider or bundled Catalog first."
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
                    Button("Capture In-Window (Provider)") {
                        startAtlasProvider()
                    }
                    if atlasProvider != nil {
                        Button("Recalibrate") {
                            atlasProvider?.recalibrate()
                        }
                    }
                    if let providerStatus {
                        Text(providerStatus)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("The product path calibrates paired hidden probes: Main-On inside this active control window and a same-context Main-Off witness inside a transparent nonactivating panel. It publishes and persists nothing until every appearance × Regular/Clear × size pair proves the active rim gate plus an independent render-margin or shader-vector branch difference.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Load Provider") { loadSavedProviderAtlas() }
                    Button("Load Bundled Catalog") { loadBundledCatalog() }
                }
                Text("Golden is the only release-evidence producer. This page loads the runtime Provider cache or the Catalog deterministically generated from accepted Golden; it never captures or exports release evidence.")
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
                    description: "A borderless non-activating floating panel rendering an AdjustableGlassEffectView frozen from the paired atlas. Normal holds verified Main-On; Muted holds verified Main-Off. The panel itself never becomes key or main."
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

            Picker("Emphasis", selection: hudMutedBinding) {
                Text("Normal").tag(false)
                Text("Muted").tag(true)
            }
            .pickerStyle(.segmented)

            labeledSlider("Glass Visibility", value: hudStrengthBinding, in: 0...1)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: hudTintEnabledBinding) {
                    LabRowLabel(
                        "Tint",
                        description: "Applies immediately; the paired Normal/Muted hue matrices auto-lock about half a second after you settle on a color — this main window supplies the genuine active side of the proof."
                    )
                }
                ColorPicker(
                    "Tint Color",
                    selection: hudTintColorBinding,
                    supportsOpacity: true
                )
                .disabled(!hudTintEnabled)
                Button("Show Main-On Reference in Test Window") {
                    showMainOnTintReference()
                }
                Text("A/B: configures the visible test window as a genuinely main window with the HUD's exact context — variant, appearance, size, and tint — so the frozen replica and the real thing sit side by side.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Height caps at the atlas's top sampled short side (320pt):
            // `sample(for:at:)` clamps above the final capture, so exposing a
            // larger short side would silently serve the 320pt payload —
            // wrong for size-dependent fields like `marginWidth`. The width
            // may exceed it freely: only `min(width, height)` selects the
            // sample, so the short side never exceeds 320 in these ranges.
            labeledSlider("Content Width", value: hudContentWidthBinding, in: 120...560)
            labeledSlider("Content Height", value: hudContentHeightBinding, in: 48...320)

            DisclosureGroup(
                isExpanded: $hudRenderExperimentExpanded
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Toggle(
                            "Shadow",
                            isOn: hudRenderPassBinding(.shadow)
                        )
                        Toggle(
                            "Ring Shadow",
                            isOn: hudRenderPassBinding(.ringShadow)
                        )
                        Toggle(
                            "Bleed",
                            isOn: hudRenderPassBinding(.bleed)
                        )
                        Toggle(
                            "Outer Refraction",
                            isOn: hudRenderPassBinding(.outerRefraction)
                        )
                    }

                    Toggle("Native Margin", isOn: hudNativeMarginBinding)
                    labeledSlider(
                        "Margin Width",
                        value: hudExperimentalMarginWidthBinding,
                        in: 0...120
                    )
                    .disabled(hudExperimentalMarginWidth == nil)

                    Text(hudRenderExperimentSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Text("Debug-only SPI. Pass toggles isolate the frozen material's outer families; Native Margin restores the Atlas value, while the slider replaces marginWidth before the OS-specific safety inset is added.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } label: {
                Text("Render Experiment (SPI)")
            }

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
                    .disabled(isRunningAtlasReadback || atlasDocument == nil)
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
            return "No atlas in memory.\nProvider: "
                + ((try? Self.providerAtlasStorageURL().path) ?? "unavailable")
                + "\nBundled Catalog: glass-macos-<major>.json"
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
        lines.append(
            "Main-On paired proof: "
                + (atlas.hasVerifiedMainOnPayload() ? "VERIFIED" : "INVALID")
        )
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
        _ = hudStatusRevision
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
                controller.onStatusChanged = {
                    hudStatusRevision &+= 1
                }
                hudPanelController = controller
                controller.setAtlas(atlasDocument)
                controller.setAppearance(hudAppearance)
                controller.setClear(hudIsClear)
                controller.setMuted(hudIsMuted)
                controller.setStrength(hudStrength)
                controller.setTint(currentHUDTintColor())
                controller.setContentSize(CGSize(
                    width: hudContentWidth,
                    height: hudContentHeight
                ))
                controller.setRenderExperiment(
                    outerPasses: hudExperimentalOuterPasses,
                    marginWidth: hudExperimentalMarginWidth.map { CGFloat($0) }
                )
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

    private var hudMutedBinding: Binding<Bool> {
        Binding { hudIsMuted } set: { isMuted in
            hudIsMuted = isMuted
            hudPanelController?.setMuted(isMuted)
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

    private func hudRenderPassBinding(
        _ pass: AdjustableGlassOuterPasses
    ) -> Binding<Bool> {
        Binding {
            hudExperimentalOuterPasses.contains(pass)
        } set: { enabled in
            if enabled {
                hudExperimentalOuterPasses.insert(pass)
            } else {
                hudExperimentalOuterPasses.remove(pass)
            }
            pushHUDRenderExperiment()
        }
    }

    private var hudNativeMarginBinding: Binding<Bool> {
        Binding {
            hudExperimentalMarginWidth == nil
        } set: { usesNativeMargin in
            if usesNativeMargin {
                hudExperimentalMarginWidth = nil
            } else {
                hudExperimentalMarginWidth = estimatedHUDNativeMarginWidth
            }
            pushHUDRenderExperiment()
        }
    }

    private var hudExperimentalMarginWidthBinding: Binding<Double> {
        Binding {
            hudExperimentalMarginWidth ?? estimatedHUDNativeMarginWidth
        } set: { value in
            hudExperimentalMarginWidth = value
            pushHUDRenderExperiment()
        }
    }

    private var estimatedHUDNativeMarginWidth: Double {
        if let hudPanelController {
            return max(
                0,
                Double(hudPanelController.nativeRequiredWindowInset - 1)
            )
        }
        return max(16, 0.35 * min(hudContentWidth, hudContentHeight))
    }

    private var hudRenderExperimentSummary: String {
        let disabled: [String] = [
            hudExperimentalOuterPasses.contains(.shadow) ? nil : "Shadow",
            hudExperimentalOuterPasses.contains(.ringShadow) ? nil : "Ring",
            hudExperimentalOuterPasses.contains(.bleed) ? nil : "Bleed",
            hudExperimentalOuterPasses.contains(.outerRefraction) ? nil : "Outer",
        ].compactMap { $0 }
        let passes = disabled.isEmpty
            ? "passes: all"
            : "passes: −" + disabled.joined(separator: ",")
        let margin = hudExperimentalMarginWidth.map {
            String(format: "marginWidth: %.0fpt", $0)
        } ?? "marginWidth: native"
        let inset = hudPanelController.map {
            String(format: "window room: %.0fpt", $0.currentInset)
        } ?? "window room: HUD hidden"
        return [passes, margin, inset].joined(separator: " · ")
    }

    private func pushHUDRenderExperiment() {
        hudPanelController?.setRenderExperiment(
            outerPasses: hudExperimentalOuterPasses,
            marginWidth: hudExperimentalMarginWidth.map { CGFloat($0) }
        )
    }

    private func pushHUDContentSize() {
        hudPanelController?.setContentSize(CGSize(
            width: hudContentWidth,
            height: hudContentHeight
        ))
    }

    /// The effective HUD tint. The picker keeps a visible default (coral at
    /// 60%) so the panel's remembered opacity slider can never silently turn
    /// every picked color into "no tint" — the trap the earlier
    /// zero-opacity-means-nil binding fell into.
    func currentHUDTintColor() -> NSColor? {
        guard hudTintEnabled else { return nil }
        let nsColor = NSColor(hudTint)
        return nsColor.alphaComponent == 0 ? nil : nsColor
    }

    private var hudTintEnabledBinding: Binding<Bool> {
        Binding { hudTintEnabled } set: { enabled in
            hudTintEnabled = enabled
            hudPanelController?.setTint(currentHUDTintColor())
            if enabled { scheduleTintAutoLock() } else { tintLockTask?.cancel() }
        }
    }

    private var hudTintColorBinding: Binding<Color> {
        Binding { hudTint } set: { color in
            hudTint = color
            hudPanelController?.setTint(currentHUDTintColor())
            scheduleTintAutoLock()
        }
    }

    /// Capture-on-pick, debounced: the tint applies immediately in this lab
    /// vehicle, and the paired Normal/Muted hue matrices lock through the
    /// provider about half a second after the user settles on a color.
    func scheduleTintAutoLock() {
        tintLockTask?.cancel()
        guard currentHUDTintColor() != nil else { return }
        tintLockTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let tint = currentHUDTintColor() else {
                return
            }
            if atlasProvider == nil { startAtlasProvider() }
            guard let provider = atlasProvider else { return }
            let hasPairedTintCoverage = [true, false].allSatisfy { hasMain in
                [true, false].allSatisfy { isLight in
                    [false, true].allSatisfy { isClear in
                        provider.atlas.tintMatrix(
                            for: .init(
                                isLightAppearance: isLight,
                                isClear: isClear,
                                hasMainParticipation: hasMain
                            ),
                            matching: tint
                        ) != nil
                    }
                }
            }
            if hasPairedTintCoverage { return }
            atlasStatus = "Locking Normal/Muted tint hue…"
            provider.captureTintMatrices(for: tint) { success in
                if success {
                    atlasDocument = provider.atlas
                    hudPanelController?.setAtlas(provider.atlas)
                    atlasStatus = "Normal/Muted tint hue locked."
                } else {
                    atlasStatus = "Tint lock needs this window main and the "
                        + "app active; it retries on your next change."
                }
            }
        }
    }

    // MARK: - Persistence

    private static func atlasStorageDirectoryURL() throws -> URL {
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
        return directory
    }

    static func providerAtlasStorageURL() throws -> URL {
        try atlasStorageDirectoryURL().appendingPathComponent(
            "glass-main-on-provider-v2.json"
        )
    }

    func loadSavedProviderAtlas() {
        loadSavedAtlas(at: try? Self.providerAtlasStorageURL())
    }

    func loadBundledCatalog() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        loadSavedAtlas(
            at: GlassMaterialAtlasCatalog.bundledAtlasURL(
                forMacOSMajor: major
            )
        )
    }

    private func loadSavedAtlas(at url: URL?) {
        do {
            guard let url else {
                throw AtlasBenchError.captureFailed("atlas storage URL")
            }
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
            let exactBuild = atlas.environment?
                .isExactBuildMatch(with: current) ?? false
            let sameDisplay = atlas.environment?.displaySignature
                == current.displaySignature
            let verified = atlas.hasVerifiedMainOnPayload()
            atlasStatus = "Loaded \(url.lastPathComponent)"
                + (compatible ? " · major compatible" : " · MAJOR INCOMPATIBLE")
                + (exactBuild ? " · exact build" : " · different build")
                + (sameDisplay ? "" : " · display advisory mismatch")
                + (verified ? " · paired proof verified" : " · PAIRED PROOF INVALID")
            hudPanelController?.setAtlas(atlasDocument)
        } catch {
            atlasStatus = "Load failed: \(error.localizedDescription)"
        }
    }

    /// One-click A/B reference: the visible test window takes the HUD's
    /// exact context with real Main participation, so a rendering-level
    /// difference (anything below the CA model, which diffs clean) shows up
    /// to the eye immediately.
    func showMainOnTintReference() {
        state.rendererMode = .recipe
        selectedRecipePage = .general
        state.isTestWindowVisible = true
        state.windowHostType = .panel
        state.testBackdrop = .ambient
        state.isSubdued = false
        state.hasScrim = false
        state.subvariant = ""
        state.adaptiveAppearance = 2
        state.variant = hudIsClear ? 2 : 1
        state.testAppearance = switch hudAppearance {
        case .light: .light
        case .dark: .dark
        case .auto: .system
        }
        state.glassWidth = hudContentWidth
        state.glassHeight = hudContentHeight
        state.cornerRadius = 24
        state.windowPadding = 120
        state.tintColor = currentHUDTintColor()
        state.isTestWindowMain = true
        state.testWindow.sync(with: state)
        state.testWindow.rebuildGlass(with: state)
    }

    // MARK: - In-window provider

    func startAtlasProvider() {
        let provider: GlassMaterialAtlasProvider
        if let existing = atlasProvider {
            provider = existing
        } else {
            guard let window = state.testWindow.liveControlWindow
                ?? NSApp.mainWindow else {
                providerStatus = "No control window available."
                return
            }
            guard let probeHost = state.testWindow.liveControlProbeHost,
                  probeHost.window === window else {
                providerStatus =
                    "No supported control-window probe host available."
                return
            }
            provider = GlassMaterialAtlasProvider(
                hostWindow: window,
                probeHostView: probeHost,
                shortSides: Self.atlasProbeShortSides,
                storageURL: try? Self.providerAtlasStorageURL(),
                certifiedAtlasURLs:
                    GlassMaterialAtlasCatalog.bundledAtlasURLs()
            )
            provider.onStateChanged = { newState in
                providerStatus = Self.describeProviderState(newState)
                    + (newState == .ready
                        ? " · \(provider.atlasSource.rawValue)"
                        : "")
            }
            provider.onAtlasUpdated = { updated in
                atlasDocument = updated
                hudPanelController?.setAtlas(updated)
            }
            atlasProvider = provider
        }
        provider.ensureCaptured()
    }

    static func describeProviderState(
        _ state: GlassMaterialAtlasProvider.State
    ) -> String {
        switch state {
        case .idle: "idle"
        case .waitingForMainWindow:
            "waiting for this window to be main and the app active"
        case let .capturing(completed, total): "capturing \(completed)/\(total)"
        case .ready: "ready — paired Normal/Muted coverage complete"
        case let .failed(reason): "failed: \(reason)"
        }
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

    /// Captures the Main-On tint matrix for this color in all four
    /// appearance × material cells via the visible probe sweep. The
    /// interactive path auto-locks through the in-window provider instead
    /// (`scheduleTintAutoLock`); this remains the reference used by the
    /// headless verification.
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
        guard !isRunningAtlasReadback else { return }
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
                for (key, liveValue) in pair.0.inputs {
                    guard let atlasValue = pair.1.inputs[key] else {
                        offenders.append(
                            "matrix\(slot).\(key): missing from atlas"
                        )
                        continue
                    }
                    note("matrix\(slot).\(key)", liveValue, atlasValue)
                }
                if pair.0.nilInputKeys != pair.1.nilInputKeys {
                    let delta = pair.0.nilInputKeys
                        .symmetricDifference(pair.1.nilInputKeys)
                    offenders.append(
                        "matrix\(slot) nilInputKeys differ: "
                            + delta.sorted().joined(separator: ", ")
                    )
                }
            }
        } else {
            offenders.append("matrix slot count mismatch")
        }

        if live.rims.count == interpolated.rims.count {
            for (slot, pair) in zip(live.rims, interpolated.rims).enumerated() {
                note(
                    "rim\(slot).layerOpacity",
                    pair.0.layerOpacity,
                    pair.1.layerOpacity
                )
                for (key, liveValue) in pair.0.values {
                    guard let atlasValue = pair.1.values[key] else {
                        offenders.append("rim\(slot).\(key): missing from atlas")
                        continue
                    }
                    note("rim\(slot).\(key)", liveValue, atlasValue)
                }
                for (key, liveValue) in pair.0.colors {
                    guard let atlasValue = pair.1.colors[key] else {
                        offenders.append(
                            "rim\(slot).\(key): color missing from atlas"
                        )
                        continue
                    }
                    note("rim\(slot).\(key).r", liveValue.red, atlasValue.red)
                    note("rim\(slot).\(key).g", liveValue.green, atlasValue.green)
                    note("rim\(slot).\(key).b", liveValue.blue, atlasValue.blue)
                    note("rim\(slot).\(key).a", liveValue.alpha, atlasValue.alpha)
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
            // Stream each step as it lands: the run takes minutes and stalls
            // are otherwise invisible until exit. stderr writes are
            // unbuffered, so a stuck run shows its last completed step.
            FileHandle.standardError.write(Data(
                "[\(steps.count)] \(passed ? "PASS" : "FAIL") \(name) — \(detail)\n"
                    .utf8
            ))
        }

        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard let catalogURL = GlassMaterialAtlasCatalog.bundledAtlasURL(
            forMacOSMajor: major
        ) else {
            throw AtlasBenchError.atlasMissing
        }
        let atlas = try JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: Data(contentsOf: catalogURL)
        )
        guard atlas.hasVerifiedMainOnPayload() else {
            throw AtlasBenchError.captureFailed("bundled Catalog topology")
        }
        step("atlas-source", true, "bundled Catalog for macOS \(major)")

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
        step(
            "decoded-main-on-proof",
            decoded.hasVerifiedMainOnPayload(),
            "every Main-On sample retains a paired Main-Off witness"
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
        // This smoke test verifies the bundled Catalog loaded above. The
        // interactive HUD deliberately starts with the product's contained
        // no-outer-shadow experiment, whose margin and shadow inputs are
        // transformed after atlas lookup. Make the headless contract explicit
        // so those intentional product overrides are never compared with the
        // untransformed Golden sample.
        hud.setRenderExperiment(
            outerPasses: .all,
            marginWidth: nil
        )
        // Show unfrozen first: the system-resolved margin on this
        // never-key-never-main panel is the reference for who wins later.
        hud.show()
        try await Task.sleep(for: .milliseconds(1200))
        if let glass = hud.glassView {
            let experiment = glass.materialStrength.renderExperiment
            step(
                "verification-policy-native",
                experiment == GlassMaterialRenderExperiment(),
                experiment == GlassMaterialRenderExperiment()
                    ? "all passes · native margin · native window inset"
                    : "headless verification inherited a product override"
            )
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
        let installedAtlasMatchesCatalog: Bool
        if let installed = hud.glassView?.materialStrength.frozenAtlas {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let installedData = try? encoder.encode(installed),
               let referenceData = try? encoder.encode(decoded) {
                installedAtlasMatchesCatalog = installedData == referenceData
            } else {
                installedAtlasMatchesCatalog = false
            }
        } else {
            installedAtlasMatchesCatalog = false
        }
        step(
            "verification-atlas-owner",
            installedAtlasMatchesCatalog,
            installedAtlasMatchesCatalog
                ? "bundled Catalog remains the sole installed source"
                : "another controller replaced the bundled Catalog"
        )
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

                    // At G = 1 the written payload equals the sample exactly
                    // — the appearance axis lives largely in the colors and
                    // grades, so a face-opacity endpoint alone would miss a
                    // restamp that reverts only part of the transplant. Poll
                    // every group: the full numeric shader vector, the color
                    // inputs, both grade matrices, and each rim's gate,
                    // payload, and colors.
                    hud.setStrength(1)
                    var numericsOK = false
                    var numericMismatches: [String] = []
                    var colorsOK = false
                    var gradesOK = false
                    var rimsOK = false
                    for _ in 0..<20 {
                        try await Task.sleep(for: .milliseconds(200))
                        if let target =
                            GlassMaterialAccess.glassBackgroundTarget(
                                under: glass
                            ) {
                            let inputs = GlassMaterialAccess.readTypedInputs(
                                from: target
                            )
                            numericMismatches = expected.numeric.compactMap {
                                key, expectedValue in
                                guard let liveValue = inputs.numeric[key] else {
                                    return "\(key): missing"
                                }
                                guard abs(liveValue - expectedValue) >= 1e-3
                                else { return nil }
                                return String(
                                    format: "%@ live %.6f vs atlas %.6f",
                                    key,
                                    liveValue,
                                    expectedValue
                                )
                            }
                            .sorted()
                            numericsOK = numericMismatches.isEmpty
                            colorsOK = expected.colors.allSatisfy { key, value in
                                inputs.colors[key].map {
                                    GlassMaterialAccess.colorsMatch(
                                        $0,
                                        value.nsColor
                                    )
                                } ?? false
                            }
                        }
                        let rimLayers = GlassMaterialAccess.rimLayers(
                            under: glass
                        )
                        rimsOK = rimLayers.count == expected.rims.count
                            && zip(rimLayers, expected.rims).allSatisfy {
                                layer, rim in
                                var rimColors: [String: NSColor] = [:]
                                for (key, color) in rim.colors {
                                    rimColors[key] = color.nsColor
                                }
                                return abs(
                                    GlassMaterialAccess.rimOpacity(of: layer)
                                        - rim.layerOpacity
                                ) < 1e-3
                                    && GlassMaterialAccess.rimPayloadMatches(
                                        values: rim.values,
                                        colors: rimColors,
                                        on: layer
                                    )
                            }
                        let gradeLayers =
                            GlassMaterialAccess.untintedMatrixLayers(
                                under: glass
                            )
                        gradesOK = gradeLayers.count == expected.matrices.count
                        if gradesOK {
                            for (layer, slot) in zip(
                                gradeLayers,
                                expected.matrices
                            ) {
                                guard let current =
                                    GlassMaterialAccess.colorMatrix(
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
                        if numericsOK, colorsOK, gradesOK, rimsOK { break }
                    }
                    step(
                        "shader-tracks-atlas \(context)",
                        numericsOK,
                        numericsOK
                            ? "\(expected.numeric.count) numeric inputs vs atlas at G=1"
                            : numericMismatches.joined(separator: " · ")
                    )
                    step(
                        "colors-track-atlas \(context)",
                        colorsOK,
                        "\(expected.colors.count) color inputs vs atlas at G=1"
                    )
                    step(
                        "grades-track-atlas \(context)",
                        gradesOK,
                        "both untinted matrices vs atlas at G=1"
                    )
                    step(
                        "rims-track-atlas \(context)",
                        rimsOK,
                        "\(expected.rims.count) rim gates + payloads vs atlas at G=1"
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

        // In-window provider end-to-end: attach to the app's real control
        // window, capture the Main-On cells with invisible clipped probes,
        // and require sample equivalence with the visible sweep — the
        // empirical proof that an obscured probe resolves identically.
        state.isTestWindowMain = false
        state.testWindow.sync(with: state)
        try await Task.sleep(for: .milliseconds(600))
        if let controlWindow = state.testWindow.liveControlWindow,
           let probeHost = state.testWindow.liveControlProbeHost,
           probeHost.window === controlWindow {
            // Simulate the user working in the window: the provider's whole
            // premise is capturing at real main/active moments.
            NSApplication.shared.activate(ignoringOtherApps: true)
            controlWindow.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            let providerSides: [Double] = [64, 96, 160]
            let provider = GlassMaterialAtlasProvider(
                hostWindow: controlWindow,
                probeHostView: probeHost,
                shortSides: providerSides,
                storageURL: nil
            )
            provider.ensureCaptured()
            var waitedMs = 0
            while !provider.isMainOnCoverageComplete, waitedMs < 30000 {
                // Cooperative activation can deny the first request when the
                // user is working in another app; keep asking politely.
                if !NSApp.isActive || !(controlWindow.isMainWindow
                    || controlWindow.isKeyWindow) {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    controlWindow.makeKeyAndOrderFront(nil)
                }
                try await Task.sleep(for: .milliseconds(300))
                waitedMs += 300
                if case .failed = provider.state { break }
            }
            step(
                "provider-completes",
                provider.isMainOnCoverageComplete,
                Self.describeProviderState(provider.state)
                    + " after \(waitedMs)ms"
            )
            step(
                "provider-paired-proof",
                provider.atlas.hasVerifiedMainOnCoverage(
                    shortSides: providerSides
                ),
                "runtime calibration committed only paired samples"
            )
            if provider.isMainOnCoverageComplete {
                var worstRelative = 0.0
                var worstContext = "none"
                for isLight in [true, false] {
                    for isClear in [false, true] {
                        let cell = GlassMaterialStyleAtlas.Cell(
                            isLightAppearance: isLight,
                            isClear: isClear,
                            hasMainParticipation: true
                        )
                        for side in providerSides {
                            guard let hidden = provider.atlas.sample(
                                for: cell,
                                at: side
                            ), let visible = decoded.sample(
                                for: cell,
                                at: side
                            ) else { continue }
                            let diff = Self.compareSamples(
                                live: hidden,
                                interpolated: visible
                            )
                            if diff.maxRelative > worstRelative {
                                worstRelative = diff.maxRelative
                                worstContext = "\(Self.cellLabel(cell)) @ "
                                    + "\(Int(side)) (\(diff.worstKey))"
                            }
                        }
                    }
                }
                step(
                    "provider-matches-sweep",
                    worstRelative < 0.02,
                    String(
                        format: "worst %.3f%% at %@",
                        worstRelative * 100,
                        worstContext
                    )
                )
            }
        } else {
            step("provider-completes", false, "no control window")
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
            // Diagnostic: the tint matrix can be perfect while the branch
            // still renders nothing — dump the complete tint chain (layer
            // gate, filter scalars, ancestor opacities, background tint
            // keys) from the frozen HUD and from a genuine Main-On probe
            // with the same tint, side by side.
            hud.setStrength(1)
            if let hudGlass = hud.glassView {
                step(
                    "info-tint-chain-hud",
                    true,
                    Self.tintBranchDescription(hudGlass)
                )
            }
            if let controlWindow = state.testWindow.liveControlWindow,
               let content = controlWindow.contentView {
                let container = NSView(frame: .zero)
                container.wantsLayer = true
                container.layer?.masksToBounds = true
                content.addSubview(container)
                defer { container.removeFromSuperview() }
                let probe = NSGlassEffectView(frame: NSRect(
                    x: 0, y: 0, width: 320, height: 120
                ))
                probe.appearance = NSAppearance(named: .darkAqua)
                GlassMaterialAccess.setVariant(1, on: probe)
                probe.tintColor = tintColor
                container.addSubview(probe)
                probe.needsLayout = true
                probe.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(1500))
                step(
                    "info-tint-chain-mainon-probe",
                    true,
                    Self.tintBranchDescription(probe)
                )

                // The decisive comparison: a complete recursive pass-audit
                // diff between the frozen HUD tree and this genuine Main-On
                // tree. Whatever still renders differently must appear here.
                if let hudGlass = hud.glassView {
                    let hudAudit = GlassLabTuning.capturePassAuditSnapshot(
                        from: hudGlass
                    )
                    let probeAudit = GlassLabTuning.capturePassAuditSnapshot(
                        from: probe
                    )
                    step(
                        "info-tint-tree-diff",
                        true,
                        Self.passAuditDiff(hud: hudAudit, reference: probeAudit)
                    )
                }
            }

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

    /// Property-level diff between two recursive pass audits, keyed by the
    /// structural pass id. Reports value differences and passes present on
    /// only one side; capped so the step detail stays readable.
    private static func passAuditDiff(
        hud: GlassLabTuning.PassAuditSnapshot?,
        reference: GlassLabTuning.PassAuditSnapshot?
    ) -> String {
        guard let hud, let reference else { return "missing snapshot" }
        var lines: [String] = []
        let hudIDs = Set(hud.passes.keys)
        let referenceIDs = Set(reference.passes.keys)
        for id in hudIDs.subtracting(referenceIDs).sorted() {
            lines.append("only-hud: \(id)")
        }
        for id in referenceIDs.subtracting(hudIDs).sorted() {
            lines.append("only-ref: \(id)")
        }
        for id in hudIDs.intersection(referenceIDs).sorted() {
            guard let hudPass = hud.passes[id],
                  let referencePass = reference.passes[id] else { continue }
            let keys = Set(hudPass.properties.keys)
                .union(referencePass.properties.keys)
            for key in keys.sorted() {
                let hudValue = hudPass.properties[key]?.value
                    ?? hudPass.properties[key]?.state
                let referenceValue = referencePass.properties[key]?.value
                    ?? referencePass.properties[key]?.state
                if hudValue != referenceValue {
                    lines.append(
                        "\(hudPass.name ?? hudPass.objectClass).\(key): "
                            + "hud=\(hudValue ?? "absent") "
                            + "ref=\(referenceValue ?? "absent")"
                    )
                }
            }
        }
        if lines.isEmpty { return "no pass-level differences" }
        let capped = lines.prefix(60)
        return capped.joined(separator: "\n")
            + (lines.count > 60 ? "\n… \(lines.count - 60) more" : "")
    }

    /// Everything observable about the tint branch: the matrix layer's own
    /// gate, its filter scalars and nil keys, every ancestor opacity up to
    /// the glass root, and any tint-named numeric input on the background
    /// filter.
    private static func tintBranchDescription(
        _ glass: NSGlassEffectView
    ) -> String {
        guard let layer = GlassMaterialAccess.tintMatrixLayer(under: glass)
        else { return "no tint layer" }
        var parts: [String] = []
        parts.append(String(
            format: "opacity=%.3f hidden=%@",
            layer.opacity,
            layer.isHidden ? "yes" : "no"
        ))
        if let matrix = GlassMaterialAccess.colorMatrix(on: layer),
           matrix.count == 20 {
            let hueMax = matrix[0..<18].map { abs($0) }.max() ?? 0
            parts.append(String(
                format: "matrix18=%.3f hueMax=%.3f m19=%.3f",
                matrix[18], hueMax, matrix[19]
            ))
        } else {
            parts.append("no matrix")
        }
        let scalars = GlassMaterialAccess.matrixScalarInputs(on: layer)
        parts.append("inputs=" + scalars.values
            .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }
            .sorted().joined(separator: ","))
        parts.append("nilKeys=" + scalars.nilKeys.sorted().joined(separator: ","))
        var chain: [String] = []
        var current: CALayer? = layer
        while let node = current, node !== glass.layer {
            chain.append(String(
                format: "%@:%.2f%@",
                String(describing: type(of: node)),
                node.opacity,
                node.isHidden ? "(hidden)" : ""
            ))
            current = node.superlayer
        }
        parts.append("chain=" + chain.joined(separator: " > "))
        parts.append(String(
            format: "bounds=%.0fx%.0f",
            layer.bounds.width, layer.bounds.height
        ))
        parts.append(
            "animations=" + (layer.animationKeys() ?? []).joined(separator: ",")
        )
        if let presentation = layer.presentation(),
           let presented = GlassMaterialAccess.colorMatrix(on: presentation),
           presented.count == 20 {
            let hueMax = presented[0..<18].map { abs($0) }.max() ?? 0
            parts.append(String(
                format: "PRESENTED m18=%.3f hueMax=%.3f",
                presented[18], hueMax
            ))
        } else {
            parts.append("PRESENTED: unreadable")
        }
        if let target = GlassMaterialAccess.glassBackgroundTarget(
            under: glass
        ) {
            let tintKeys = GlassMaterialAccess.readTypedInputs(from: target)
                .numeric.filter { $0.key.lowercased().contains("tint") }
            parts.append("bgTintKeys=" + tintKeys
                .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }
                .sorted().joined(separator: ","))
        }
        return parts.joined(separator: " · ")
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
        // The sidebar stays usable during a capture. If the user moved to a
        // section that pins its own renderer, that section wins over the
        // snapshot — blindly restoring would leave its controls backed by
        // the wrong test surface until the next navigation change.
        state.rendererMode = state.selectedSection.requiredRendererMode
            ?? context.rendererMode
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
