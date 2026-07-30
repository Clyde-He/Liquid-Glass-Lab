//
//  GlassMaterialAtlasProvider.swift
//  LiquidGlassLab
//
//  Product calibration for a never-main HUD. A real main/key host supplies
//  the Main-On probes while a transparent nonactivating witness window
//  supplies same-context Main-Off probes. No sample is published or persisted
//  until every appearance × Regular/Clear × size pair proves the active
//  branch from resolved payload, and the whole calibration commits atomically.
//

#if os(macOS)
import AppKit

private final class GlassMaterialCalibrationWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class GlassMaterialAtlasProvider {
    /// Where a calibration currently stands, for progress UI.
    public enum State: Equatable {
        case idle
        case waitingForMainWindow
        case capturing(completed: Int, total: Int)
        case ready
        case failed(String)
    }

    /// Provenance exposed to the product so `ready` is observable rather than
    /// an ambiguous mix of bundled data, disk cache, and a live calibration.
    public enum AtlasSource: String, Equatable {
        case none
        case certified
        case cache
        case runtimeCalibration
    }

    public private(set) var atlas: GlassMaterialStyleAtlas
    public private(set) var atlasSource: AtlasSource = .none
    public private(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    /// Fires only for a complete, paired, verified atlas or a completed tint
    /// transaction. Partial base-calibration batches are never published.
    public var onAtlasUpdated: ((GlassMaterialStyleAtlas) -> Void)?
    public var onStateChanged: ((State) -> Void)?

    /// True only when every Main-On sample has exact requested-size coverage,
    /// a same-context Main-Off witness, and the atlas matches this schema and
    /// macOS major. Minor/beta builds and displays intentionally share it.
    public var isMainOnCoverageComplete: Bool {
        guard let environment = atlas.environment,
              environment.isCompatible(
                with: .current(for: hostWindow?.screen)
              )
        else { return false }
        return atlas.hasVerifiedMainOnCoverage(shortSides: shortSides)
    }

    /// Product terminology for the same gate: Main-On coverage is accepted
    /// only when every matching Main-Off witness is also present and verified.
    public var isPairedCoverageComplete: Bool {
        isMainOnCoverageComplete
    }

    private static let mainOnCells: [GlassMaterialStyleAtlas.Cell] = {
        var cells: [GlassMaterialStyleAtlas.Cell] = []
        for isLight in [true, false] {
            for isClear in [false, true] {
                cells.append(GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: true
                ))
            }
        }
        return cells
    }()

    private struct VerifiedPair {
        var shortSide: Double
        var mainOn: GlassMaterialStyleSample
        var mainOff: GlassMaterialStyleSample
    }

    private struct ProbePair {
        var shortSide: Double
        var mainOn: NSGlassEffectView
        var mainOff: NSGlassEffectView
    }

    private struct TintProbePair {
        var cell: GlassMaterialStyleAtlas.Cell
        var mainOn: NSGlassEffectView
        var mainOff: NSGlassEffectView
    }

    private struct VerifiedTintPair: Equatable {
        var mainOn: GlassMaterialStyleAtlas.TintMatrix
        var mainOff: GlassMaterialStyleAtlas.TintMatrix
    }

    private weak var hostWindow: NSWindow?
    private let shortSides: [Double]
    private let storageURL: URL?
    private let certifiedAtlasURLs: [URL]
    private let probeWidth: Double
    private var mainProbeContainer: NSView?
    private var witnessWindow: GlassMaterialCalibrationWindow?
    private var witnessProbeContainer: NSView?
    private var captureTask: Task<Void, Never>?
    private var tintCaptureTask: Task<Void, Never>?
    private var tintCaptureGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var didLoadCandidates = false
    private var pendingRecalibration = false

    /// Host flags are a scheduling precondition, never proof of the captured
    /// material. Payload proof comes from paired On/Off samples.
    private var hostParticipates: Bool {
        guard let window = hostWindow else { return false }
        return (window.isMainWindow || window.isKeyWindow) && NSApp.isActive
    }

    private var witnessIsMainOff: Bool {
        guard let window = witnessWindow else { return false }
        return window.isVisible
            && !window.isMainWindow
            && !window.isKeyWindow
            && NSApp.mainWindow !== window
            && NSApp.keyWindow !== window
    }

    /// - Parameters:
    ///   - hostWindow: The product's Settings or main window. Calibration
    ///     starts only while it is genuinely key/main and the app is active.
    ///   - shortSides: Probe sizes bracketing the HUD range and resolver gates.
    ///   - storageURL: Runtime-calibrated cache destination.
    ///   - certifiedAtlasURLs: Optional bundled, read-only atlas catalog in
    ///     preference order. The first schema + macOS-major match with paired
    ///     proof is accepted; display and minor/beta build are diagnostic only.
    public init(
        hostWindow: NSWindow,
        shortSides: [Double] = [48, 64, 96, 128, 160, 200, 320],
        storageURL: URL? = nil,
        certifiedAtlasURLs: [URL] = []
    ) {
        self.hostWindow = hostWindow
        self.shortSides = shortSides.sorted()
        self.storageURL = storageURL
        self.certifiedAtlasURLs = certifiedAtlasURLs
        self.probeWidth = max(480, (shortSides.max() ?? 320) * 1.5)
        self.atlas = GlassMaterialStyleAtlas()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Loads a certified atlas or verified runtime cache, otherwise calibrates
    /// at the next stable main/key opportunity. Idempotent.
    public func ensureCaptured() {
        observeHostWindow()
        if isMainOnCoverageComplete {
            state = .ready
            return
        }
        if !didLoadCandidates {
            didLoadCandidates = true
            if loadFirstVerifiedCandidate() {
                state = .ready
                onAtlasUpdated?(atlas)
                return
            }
        }
        captureWhenPossible()
    }

    /// Explicitly discards the in-memory candidate and performs a fresh,
    /// transactional calibration. The old disk cache remains untouched until
    /// the replacement has fully verified and can atomically overwrite it.
    public func recalibrate() {
        pendingRecalibration = captureTask != nil
        captureTask?.cancel()
        tintCaptureGeneration += 1
        tintCaptureTask?.cancel()
        atlas = GlassMaterialStyleAtlas()
        atlasSource = .none
        didLoadCandidates = true
        state = .idle
        if captureTask == nil {
            pendingRecalibration = false
            captureWhenPossible()
        }
    }

    /// Captures the paired Main-On and Main-Off tint matrices for one chosen
    /// RGB in all four appearance × variant contexts. The base atlas must
    /// already be verified. Each pair is admitted only while its base styles
    /// prove that the two hidden subtrees resolved different participation
    /// branches, then both frozen destinations must read back before commit.
    public func captureTintMatrices(
        for color: NSColor,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard isMainOnCoverageComplete else {
            ensureCaptured()
            completion(false)
            return
        }
        guard hostParticipates else {
            completion(false)
            return
        }

        tintCaptureTask?.cancel()
        tintCaptureGeneration += 1
        let generation = tintCaptureGeneration
        tintCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard generation == self.tintCaptureGeneration,
                  self.hostParticipates,
                  self.prepareWitnessWindow()
            else {
                completion(false)
                return
            }
            defer {
                if generation == self.tintCaptureGeneration {
                    self.tearDownWitnessWindow()
                    self.tintCaptureTask = nil
                }
            }

            let needed = Self.mainOnCells.filter {
                let mainOff = Self.mainOffCell(for: $0)
                return self.atlas.tintMatrix(for: $0, matching: color) == nil
                    || self.atlas.tintMatrix(
                        for: mainOff,
                        matching: color
                    ) == nil
            }
            guard !needed.isEmpty else {
                completion(true)
                return
            }
            guard let mainContainer = self.ensureMainProbeContainer(),
                  let offContainer = self.witnessProbeContainer
            else {
                completion(false)
                return
            }

            let referenceSide = min(200, self.shortSides.max() ?? 200)
            let probes = needed.map { cell -> TintProbePair in
                let offCell = Self.mainOffCell(for: cell)
                let mainOn = self.makeProbe(
                    cell: cell,
                    shortSide: referenceSide,
                    in: mainContainer
                )
                let mainOff = self.makeProbe(
                    cell: offCell,
                    shortSide: referenceSide,
                    in: offContainer
                )
                mainOn.tintColor = color
                mainOff.tintColor = color
                return TintProbePair(
                    cell: cell,
                    mainOn: mainOn,
                    mainOff: mainOff
                )
            }
            defer {
                probes.forEach {
                    $0.mainOn.removeFromSuperview()
                    $0.mainOff.removeFromSuperview()
                }
            }

            try? await Task.sleep(for: .milliseconds(600))
            var previous: [
                GlassMaterialStyleAtlas.Cell:
                    VerifiedTintPair
            ] = [:]
            var stableCounts: [GlassMaterialStyleAtlas.Cell: Int] = [:]
            var accepted: [
                GlassMaterialStyleAtlas.Cell:
                    VerifiedTintPair
            ] = [:]

            for _ in 0..<30 where accepted.count < probes.count {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled,
                      generation == self.tintCaptureGeneration,
                      self.hostParticipates,
                      self.witnessIsMainOff
                else {
                    completion(false)
                    return
                }

                for pair in probes where accepted[pair.cell] == nil {
                    guard let onStyle = GlassMaterialStyleSample.capture(
                        from: pair.mainOn
                    ), let offStyle = GlassMaterialStyleSample.capture(
                        from: pair.mainOff
                    ), GlassMaterialStyleAtlas.verifiesMainOn(
                        onStyle,
                        against: offStyle
                    ), let onMatrix = GlassMaterialStyleAtlas.captureTintMatrix(
                        from: pair.mainOn
                    ), let offMatrix = GlassMaterialStyleAtlas.captureTintMatrix(
                        from: pair.mainOff
                    ), onMatrix.matrix.count == 20,
                    offMatrix.matrix.count == 20
                    else {
                        previous[pair.cell] = nil
                        stableCounts[pair.cell] = 0
                        continue
                    }

                    let matrices = VerifiedTintPair(
                        mainOn: onMatrix,
                        mainOff: offMatrix
                    )
                    if previous[pair.cell] == matrices {
                        let count = (stableCounts[pair.cell] ?? 0) + 1
                        stableCounts[pair.cell] = count
                        if count >= 2 { accepted[pair.cell] = matrices }
                    } else {
                        previous[pair.cell] = matrices
                        stableCounts[pair.cell] = 0
                    }
                }
            }

            guard accepted.count == probes.count else {
                completion(false)
                return
            }
            var candidate = self.atlas
            for (cell, matrices) in accepted {
                candidate.addTintMatrix(matrices.mainOn, for: cell)
                candidate.addTintMatrix(
                    matrices.mainOff,
                    for: Self.mainOffCell(for: cell)
                )
            }
            guard await self.validateFrozenTintRoundTrip(
                candidate,
                color: color
            ) else {
                completion(false)
                return
            }
            guard !Task.isCancelled,
                  generation == self.tintCaptureGeneration
            else {
                completion(false)
                return
            }
            self.atlas = candidate
            do {
                try self.persist()
            } catch {
                self.state = .failed(
                    "Tint verified but cache write failed: "
                        + error.localizedDescription
                )
            }
            self.onAtlasUpdated?(self.atlas)
            completion(true)
        }
    }

    // MARK: - Candidate loading

    private func loadFirstVerifiedCandidate() -> Bool {
        let cached = storageURL.flatMap(loadVerifiedAtlas(from:))
        for url in certifiedAtlasURLs {
            if var candidate = loadVerifiedAtlas(from: url) {
                if let cached {
                    candidate.mergeTintMatrices(from: cached)
                }
                atlas = candidate
                atlasSource = .certified
                return true
            }
        }
        if let cached {
            atlas = cached
            atlasSource = .cache
            return true
        }
        return false
    }

    private func loadVerifiedAtlas(
        from url: URL
    ) -> GlassMaterialStyleAtlas? {
        guard let data = try? Data(contentsOf: url),
              let candidate = try? JSONDecoder().decode(
                GlassMaterialStyleAtlas.self,
                from: data
              ),
              let environment = candidate.environment,
              environment.isCompatible(
                with: .current(for: hostWindow?.screen)
              ),
              candidate.hasVerifiedMainOnCoverage(shortSides: shortSides)
        else { return nil }
        return candidate
    }

    // MARK: - Capture scheduling

    private func observeHostWindow() {
        guard observers.isEmpty, let window = hostWindow else { return }
        let center = NotificationCenter.default
        let events: [(Notification.Name, AnyObject)] = [
            (NSWindow.didBecomeMainNotification, window),
            (NSWindow.didBecomeKeyNotification, window),
            (NSApplication.didBecomeActiveNotification, NSApp),
        ]
        for (name, object) in events {
            observers.append(center.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.captureWhenPossible()
                }
            })
        }
    }

    private func captureWhenPossible() {
        guard captureTask == nil, !isMainOnCoverageComplete else { return }
        guard hostParticipates else {
            state = .waitingForMainWindow
            return
        }
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCalibration()
            self.captureTask = nil
            if self.pendingRecalibration {
                self.pendingRecalibration = false
                self.captureWhenPossible()
            } else if self.state == .waitingForMainWindow,
                      self.hostParticipates {
                self.captureWhenPossible()
            }
        }
    }

    /// Captures all four cells as one transaction. Progress is observable, but
    /// neither `atlas` nor the disk cache changes until every On/Off pair has
    /// passed payload validation.
    private func runCalibration() async {
        guard prepareWitnessWindow() else {
            state = .failed("Could not create the Main-Off witness window.")
            return
        }
        defer { tearDownWitnessWindow() }

        try? await Task.sleep(for: .milliseconds(500))
        guard hostParticipates else {
            state = .waitingForMainWindow
            return
        }
        guard witnessIsMainOff else {
            state = .failed("Witness window unexpectedly became key or main.")
            return
        }

        var candidate = GlassMaterialStyleAtlas()
        let total = Self.mainOnCells.count * shortSides.count
        var completed = 0
        state = .capturing(completed: 0, total: total)

        for cell in Self.mainOnCells {
            guard let pairs = await captureVerifiedBatch(
                cell: cell,
                sizes: shortSides
            ) else { return }
            let mainOffCell = Self.mainOffCell(for: cell)
            for pair in pairs {
                candidate.add(pair.mainOn, for: cell)
                candidate.add(pair.mainOff, for: mainOffCell)
            }
            completed += pairs.count
            state = .capturing(completed: completed, total: total)
        }

        candidate.environment = .current(for: hostWindow?.screen)
        guard candidate.hasVerifiedMainOnCoverage(shortSides: shortSides) else {
            state = .failed(
                "Calibration completed without a full paired Main-On proof."
            )
            return
        }
        guard await validateFrozenRoundTrip(candidate) else {
            state = .failed(
                "Paired capture passed, but the frozen witness did not read "
                    + "back both complete Normal and Muted payloads."
            )
            return
        }

        atlas = candidate
        atlasSource = .runtimeCalibration
        do {
            try persist()
        } catch {
            state = .failed(
                "Calibration verified but cache write failed: "
                    + error.localizedDescription
            )
            onAtlasUpdated?(atlas)
            return
        }
        state = .ready
        onAtlasUpdated?(atlas)
    }

    private func captureVerifiedBatch(
        cell: GlassMaterialStyleAtlas.Cell,
        sizes: [Double]
    ) async -> [VerifiedPair]? {
        guard let mainContainer = ensureMainProbeContainer(),
              let offContainer = witnessProbeContainer
        else {
            state = .failed("Probe containers are unavailable.")
            return nil
        }

        let mainOffCell = Self.mainOffCell(for: cell)
        let probes = sizes.map { shortSide in
            ProbePair(
                shortSide: shortSide,
                mainOn: makeProbe(
                    cell: cell,
                    shortSide: shortSide,
                    in: mainContainer
                ),
                mainOff: makeProbe(
                    cell: mainOffCell,
                    shortSide: shortSide,
                    in: offContainer
                )
            )
        }
        defer {
            probes.forEach {
                $0.mainOn.removeFromSuperview()
                $0.mainOff.removeFromSuperview()
            }
        }

        hostWindow?.contentView?.layoutSubtreeIfNeeded()
        witnessWindow?.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))

        var previousOn: [Double: GlassMaterialStyleSample] = [:]
        var previousOff: [Double: GlassMaterialStyleSample] = [:]
        var stableCounts: [Double: Int] = [:]
        var accepted: [Double: VerifiedPair] = [:]
        var lastObserved: (
            onMargin: Double,
            offMargin: Double,
            onRim: Double,
            offRim: Double
        )?

        for _ in 0..<30 where accepted.count < probes.count {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return nil }
            guard hostParticipates else {
                state = .waitingForMainWindow
                return nil
            }
            guard witnessIsMainOff else {
                state = .failed("Main-Off witness lost its participation state.")
                return nil
            }

            for probe in probes where accepted[probe.shortSide] == nil {
                guard let mainOn = GlassMaterialStyleSample.capture(
                    from: probe.mainOn
                ), let mainOff = GlassMaterialStyleSample.capture(
                    from: probe.mainOff
                ) else {
                    previousOn[probe.shortSide] = nil
                    previousOff[probe.shortSide] = nil
                    stableCounts[probe.shortSide] = 0
                    continue
                }
                lastObserved = (
                    mainOn.marginWidth,
                    mainOff.marginWidth,
                    mainOn.rims.first?.layerOpacity ?? .nan,
                    mainOff.rims.first?.layerOpacity ?? .nan
                )
                guard GlassMaterialStyleAtlas.verifiesMainOn(
                    mainOn,
                    against: mainOff
                ) else {
                    previousOn[probe.shortSide] = mainOn
                    previousOff[probe.shortSide] = mainOff
                    stableCounts[probe.shortSide] = 0
                    continue
                }

                if previousOn[probe.shortSide] == mainOn,
                   previousOff[probe.shortSide] == mainOff {
                    let count = (stableCounts[probe.shortSide] ?? 0) + 1
                    stableCounts[probe.shortSide] = count
                    if count >= 2 {
                        accepted[probe.shortSide] = VerifiedPair(
                            shortSide: probe.shortSide,
                            mainOn: mainOn,
                            mainOff: mainOff
                        )
                    }
                } else {
                    previousOn[probe.shortSide] = mainOn
                    previousOff[probe.shortSide] = mainOff
                    stableCounts[probe.shortSide] = 0
                }
            }
        }

        guard accepted.count == probes.count else {
            let label = "\(cell.isLightAppearance ? "Light" : "Dark")·"
                + "\(cell.isClear ? "Clear" : "Regular")"
            if let lastObserved {
                state = .failed(String(
                    format: "%@ resolved without Main-On proof "
                        + "(margin %.2f/%.2f, rim %.2f/%.2f).",
                    label,
                    lastObserved.onMargin,
                    lastObserved.offMargin,
                    lastObserved.onRim,
                    lastObserved.offRim
                ))
            } else {
                state = .failed("\(label) never produced complete paired samples.")
            }
            return nil
        }
        return sizes.compactMap { accepted[$0] }
    }

    /// Final transaction gate: install both participation branches on real
    /// never-key, never-main `GlassMaterialEffectView` consumers for every
    /// appearance × variant cell and require the complete readback sentinel.
    /// Capture proof and Normal/Muted consumer proof therefore fail together
    /// before disk.
    private func validateFrozenRoundTrip(
        _ candidate: GlassMaterialStyleAtlas
    ) async -> Bool {
        guard let container = witnessProbeContainer,
              let referenceSide = shortSides.min(by: {
                  abs($0 - 200) < abs($1 - 200)
              })
        else { return false }

        var consumers: [(glass: GlassMaterialEffectView, hasMain: Bool)] = []
        for cell in Self.mainOnCells {
            for hasMain in [true, false] {
                let glass = GlassMaterialEffectView(frame: NSRect(
                    x: 0,
                    y: 0,
                    width: probeWidth,
                    height: referenceSide
                ))
                glass.appearance = NSAppearance(
                    named: cell.isLightAppearance ? .aqua : .darkAqua
                )
                GlassMaterialAccess.setVariant(cell.isClear ? 2 : 1, on: glass)
                container.addSubview(glass)
                consumers.append((glass, hasMain))
            }
        }
        defer {
            consumers.forEach {
                $0.glass.materialStrength.invalidate()
                $0.glass.removeFromSuperview()
            }
        }

        witnessWindow?.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, hostParticipates, witnessIsMainOff
        else { return false }
        for consumer in consumers {
            guard consumer.glass.materialStrength.freeze(
                atlas: candidate,
                mainParticipation: consumer.hasMain
            ) else { return false }
        }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, hostParticipates, witnessIsMainOff
            else { return false }
            if consumers.allSatisfy({
                $0.glass.materialStrength.frozenStyleIsCurrentlyApplied
            }) {
                return true
            }
        }
        return false
    }

    /// Tint is committed transactionally only after both semantic
    /// participations survive a real frozen-destination round trip for every
    /// appearance × variant cell. All eight consumers are materialized
    /// together so validation adds one settle window rather than eight.
    private func validateFrozenTintRoundTrip(
        _ candidate: GlassMaterialStyleAtlas,
        color: NSColor
    ) async -> Bool {
        guard let container = witnessProbeContainer,
              let referenceSide = shortSides.min(by: {
                  abs($0 - 200) < abs($1 - 200)
              })
        else { return false }

        var consumers: [(glass: GlassMaterialEffectView, hasMain: Bool)] = []
        for cell in Self.mainOnCells {
            for hasMain in [true, false] {
                let glass = GlassMaterialEffectView(frame: NSRect(
                    x: 0,
                    y: 0,
                    width: probeWidth,
                    height: referenceSide
                ))
                glass.appearance = NSAppearance(
                    named: cell.isLightAppearance ? .aqua : .darkAqua
                )
                GlassMaterialAccess.setVariant(cell.isClear ? 2 : 1, on: glass)
                glass.materialTint = color
                container.addSubview(glass)
                consumers.append((glass, hasMain))
            }
        }
        defer {
            consumers.forEach {
                $0.glass.materialStrength.invalidate()
                $0.glass.removeFromSuperview()
            }
        }

        witnessWindow?.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, hostParticipates, witnessIsMainOff
        else { return false }

        for consumer in consumers {
            guard consumer.glass.materialStrength.freeze(
                atlas: candidate,
                mainParticipation: consumer.hasMain
            ) else { return false }
        }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, hostParticipates, witnessIsMainOff
            else { return false }
            if consumers.allSatisfy({
                $0.glass.materialStrength.frozenStyleIsCurrentlyApplied
            }) {
                return true
            }
        }
        return false
    }

    // MARK: - Probe hosts

    private static func mainOffCell(
        for mainOn: GlassMaterialStyleAtlas.Cell
    ) -> GlassMaterialStyleAtlas.Cell {
        GlassMaterialStyleAtlas.Cell(
            isLightAppearance: mainOn.isLightAppearance,
            isClear: mainOn.isClear,
            hasMainParticipation: false
        )
    }

    private func ensureMainProbeContainer() -> NSView? {
        if let mainProbeContainer,
           mainProbeContainer.superview != nil {
            return mainProbeContainer
        }
        guard let contentView = hostWindow?.contentView else { return nil }
        let container = makeClippedContainer()
        contentView.addSubview(container)
        mainProbeContainer = container
        return container
    }

    private func prepareWitnessWindow() -> Bool {
        if let witnessWindow, let witnessProbeContainer {
            witnessWindow.orderFrontRegardless()
            return witnessProbeContainer.superview != nil
        }

        let screenFrame = hostWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        let window = GlassMaterialCalibrationWindow(
            contentRect: NSRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: 1,
                height: 1
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        let container = makeClippedContainer()
        content.addSubview(container)
        window.contentView = content

        witnessWindow = window
        witnessProbeContainer = container
        window.orderFrontRegardless()
        return true
    }

    private func tearDownWitnessWindow() {
        witnessWindow?.orderOut(nil)
        witnessWindow = nil
        witnessProbeContainer = nil
    }

    private func makeClippedContainer() -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        return container
    }

    private func makeProbe(
        cell: GlassMaterialStyleAtlas.Cell,
        shortSide: Double,
        in container: NSView
    ) -> NSGlassEffectView {
        let probe = NSGlassEffectView(frame: NSRect(
            x: 0,
            y: 0,
            width: probeWidth,
            height: shortSide
        ))
        probe.appearance = NSAppearance(
            named: cell.isLightAppearance ? .aqua : .darkAqua
        )
        GlassMaterialAccess.setVariant(cell.isClear ? 2 : 1, on: probe)
        container.addSubview(probe)
        return probe
    }

    // MARK: - Persistence

    private func persist() throws {
        guard let storageURL else { return }
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(atlas).write(to: storageURL, options: .atomic)
    }
}
#endif
