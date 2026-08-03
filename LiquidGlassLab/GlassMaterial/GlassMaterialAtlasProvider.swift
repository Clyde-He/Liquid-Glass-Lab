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

@available(macOS 26.0, *)
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

    /// Fires only for a complete, paired, verified atlas or a completed legacy
    /// Tint transaction. Partial base-calibration batches are never published;
    /// the narrow commit-resolved Tint persistence seam updates its atlas
    /// synchronously without requesting a full-material callback.
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

    private(set) weak var hostWindow: NSWindow?
    /// Consumer-owned insertion point for invisible calibration probes.
    /// SwiftUI hosting-controller roots are not safe to mutate directly.
    private(set) weak var probeHostView: NSView?
    private let shortSides: [Double]
    private let storageURL: URL?
    private let certifiedAtlasURLs: [URL]
    private let certifiedFallbackAtlases: [GlassMaterialStyleAtlas]
    private let probeWidth: Double
    private var mainProbeContainer: NSView?
    private var witnessWindow: GlassMaterialCalibrationWindow?
    private var witnessProbeContainer: NSView?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = 0
    private var tintCaptureTask: Task<Void, Never>?
    private var tintCaptureGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var didLoadCandidates = false
    /// Generation of the cancelled base-capture task whose cleanup should
    /// launch an explicitly requested recalibration. Host rebind cancellation
    /// never sets this handshake, so stale host work cannot disturb a newer
    /// task.
    private var pendingRecalibrationGeneration: Int?
    private var isInvalidated = false

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
        hostWindow: NSWindow?,
        probeHostView: NSView? = nil,
        shortSides: [Double] = [48, 64, 96, 128, 160, 200, 320],
        storageURL: URL? = nil,
        certifiedAtlasURLs: [URL] = []
    ) {
        self.hostWindow = hostWindow
        self.probeHostView = probeHostView
        self.shortSides = shortSides.sorted()
        self.storageURL = storageURL
        self.certifiedAtlasURLs = certifiedAtlasURLs
        self.certifiedFallbackAtlases = certifiedAtlasURLs.compactMap {
            Self.loadCertifiedFallbackAtlas(from: $0)
        }
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
        guard !isInvalidated else { return }
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
        guard !isInvalidated else { return }
        pendingRecalibrationGeneration = captureTask == nil
            ? nil
            : captureGeneration
        captureGeneration += 1
        captureTask?.cancel()
        tintCaptureGeneration += 1
        tintCaptureTask?.cancel()
        // Clear the independent Tint handle here so a later
        // `cancelTintCapture` cannot mistake it for a live transaction and
        // tear down the witness window while the base-calibration handshake
        // above is waiting to launch its fresh generation.
        tintCaptureTask = nil
        atlas = GlassMaterialStyleAtlas()
        atlasSource = .none
        didLoadCandidates = true
        state = .idle
        if captureTask == nil {
            pendingRecalibrationGeneration = nil
            captureWhenPossible()
        }
    }

    /// Re-targets calibration at a different reference host without discarding
    /// the verified atlas or its persisted Tint overlay.
    ///
    /// A reference host is a calibration capability, not ownership of the
    /// captured material: the current atlas, source, and ready state survive
    /// the transition. Only host-bound machinery is rebuilt — notification
    /// registrations, the probe container (which lives in the previous host's
    /// view tree), the witness window, and any in-flight capture against the
    /// previous host. Returns false when the effective pair is unchanged.
    @discardableResult
    func rebindReferenceHost(
        hostWindow: NSWindow?,
        probeHostView: NSView?
    ) -> Bool {
        guard hostWindow !== self.hostWindow
                || probeHostView !== self.probeHostView
        else { return false }
        self.hostWindow = hostWindow
        self.probeHostView = probeHostView
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        mainProbeContainer?.removeFromSuperview()
        mainProbeContainer = nil
        tintCaptureGeneration += 1
        tintCaptureTask?.cancel()
        tintCaptureTask = nil
        tearDownWitnessWindow()
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        pendingRecalibrationGeneration = nil
        observeHostWindow()
        return true
    }

    /// Stops a color-specific transaction when its product consumer goes
    /// away. Base calibration is deliberately left alone so a later attach can
    /// still reuse it.
    public func cancelTintCapture() {
        guard tintCaptureTask != nil else { return }
        tintCaptureGeneration += 1
        tintCaptureTask?.cancel()
        tintCaptureTask = nil
        tearDownWitnessWindow()
    }

    /// Stops every provider-owned transaction and releases its AppKit probes.
    /// A controller replacement must not let the old provider finish against a
    /// stale reference window or race the replacement's cache write.
    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        pendingRecalibrationGeneration = nil
        tintCaptureGeneration += 1
        tintCaptureTask?.cancel()
        tintCaptureTask = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        mainProbeContainer?.removeFromSuperview()
        mainProbeContainer = nil
        tearDownWitnessWindow()
        onAtlasUpdated = nil
        onStateChanged = nil
    }

    /// Conservative window room while the selected runtime atlas is not ready.
    /// Use the largest interpolated Main-On margin across every bundled,
    /// structurally verified catalog. If none decode, retain the worst measured
    /// ratio from the shipped evidence rather than guessing from one OS major.
    func conservativeMainOnMargin(for shortSide: Double) -> Double {
        let side = max(0, shortSide)
        if let measured = certifiedFallbackAtlases.compactMap({
            $0.maximumMainOnMargin(at: side)
        }).max() {
            return measured
        }
        return max(16, 0.71 * side)
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
        guard !isInvalidated else {
            completion(false)
            return
        }
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
            candidate.removeIncompleteTintMatrices()
            candidate.retainTintMatrices(
                upTo: GlassMaterialStyleAtlas.tintMatrixColorLimit,
                keeping: GlassMaterialColorValue(color)
            )
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
            candidate.environment = .current(for: self.hostWindow?.screen)
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

    /// Promotes one complete, commit-resolved Tint set into the runtime
    /// overlay. The resolver has already proved all eight Main-On/Main-Off
    /// pairs before calling this seam; the atlas performs a second structural
    /// gate, then the candidate is encoded and atomically written before it
    /// replaces the provider's in-memory value.
    ///
    /// This intentionally does not invoke `onAtlasUpdated`: a Tint overlay is
    /// a color-only update and must not turn the controller's narrow restamp
    /// into a full base-material freeze. The provider's atlas is updated
    /// synchronously and is therefore available to the next controller lookup.
    @discardableResult
    func persistVerifiedTintMatrices(
        sourceColor: GlassMaterialColorValue,
        matrices: [GlassMaterialStyleAtlas.Cell: [Float]],
        captureEnvironment: GlassMaterialStyleAtlas.Environment
    ) -> Bool {
        let currentEnvironment = GlassMaterialStyleAtlas.Environment.current(
            for: hostWindow?.screen
        )
        guard !isInvalidated,
              isPairedCoverageComplete,
              captureEnvironment.isCompatible(with: currentEnvironment),
              var candidate = atlas.addingVerifiedTintMatrixSet(
                  sourceColor: sourceColor,
                  matrices: matrices
              )
        else { return false }

        // Scope the runtime overlay to the environment that produced the
        // paired proof. A bundled base may carry an older diagnostic build or
        // display signature while still matching the major-scoped admission
        // contract; it must not become the overlay's provenance by accident.
        candidate.environment = captureEnvironment

        do {
            try persist(candidate)
        } catch {
            return false
        }
        atlas = candidate
        return true
    }

    // MARK: - Candidate loading

    private func loadFirstVerifiedCandidate() -> Bool {
        let cached = storageURL.flatMap(loadVerifiedAtlas(from:))
        for url in certifiedAtlasURLs {
            if var candidate = loadVerifiedAtlas(from: url) {
                // Certified assets are authoritative only for the reusable
                // base. Tint is always a color-bound runtime overlay, even if
                // a hand-authored or legacy catalog accidentally contains it.
                candidate.removeAllTintMatrices()
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
              var candidate = try? JSONDecoder().decode(
                GlassMaterialStyleAtlas.self,
                from: data
              ),
              let environment = candidate.environment,
              environment.isCompatible(
                with: .current(for: hostWindow?.screen)
              ),
              candidate.hasVerifiedMainOnCoverage(shortSides: shortSides)
        else { return nil }
        // Schema-2 caches can contain a malformed or partial runtime overlay
        // even when their base atlas is valid. Sanitize Tint independently so
        // the certified/base readiness path survives and no incomplete color
        // set can be served after a restart.
        candidate.removeIncompleteTintMatrices()
        candidate.retainTintMatrices(
            upTo: GlassMaterialStyleAtlas.tintMatrixColorLimit
        )
        return candidate
    }

    private static func loadCertifiedFallbackAtlas(
        from url: URL
    ) -> GlassMaterialStyleAtlas? {
        guard let data = try? Data(contentsOf: url),
              let candidate = try? JSONDecoder().decode(
                GlassMaterialStyleAtlas.self,
                from: data
              ),
              candidate.environment?.schemaVersion
                == GlassMaterialStyleAtlas.currentSchemaVersion,
              candidate.hasVerifiedMainOnPayload()
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
        guard !isInvalidated,
              captureTask == nil,
              !isMainOnCoverageComplete
        else { return }
        guard hostParticipates else {
            state = .waitingForMainWindow
            return
        }
        captureGeneration += 1
        let generation = captureGeneration
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCalibration(generation: generation)
            guard !self.isInvalidated else { return }
            // A host rebind clears the cancelled handle and may already have
            // installed a successor task. The stale task must not erase that
            // successor or start a second calibration against shared probes.
            // `recalibrate()` is different: it leaves the cancelled handle in
            // place and sets this handshake so that task may start the fresh
            // generation after its own cleanup.
            guard generation == self.captureGeneration else {
                guard self.pendingRecalibrationGeneration == generation
                else { return }
                self.pendingRecalibrationGeneration = nil
                self.captureTask = nil
                self.captureWhenPossible()
                return
            }
            self.captureTask = nil
            if self.state == .waitingForMainWindow,
               self.hostParticipates {
                self.captureWhenPossible()
            }
        }
    }

    /// Captures all four cells as one transaction. Progress is observable, but
    /// neither `atlas` nor the disk cache changes until every On/Off pair has
    /// passed payload validation.
    private func runCalibration(generation: Int) async {
        guard captureIsCurrent(generation) else { return }
        guard prepareWitnessWindow() else {
            state = .failed("Could not create the Main-Off witness window.")
            return
        }
        defer { tearDownWitnessWindow() }

        try? await Task.sleep(for: .milliseconds(500))
        guard captureIsCurrent(generation) else { return }
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

        guard captureIsCurrent(generation) else { return }

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

    private func captureIsCurrent(_ generation: Int) -> Bool {
        !isInvalidated
            && !Task.isCancelled
            && generation == captureGeneration
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

        resolvedProbeHostView?.layoutSubtreeIfNeeded()
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
    /// never-key, never-main `AdjustableGlassEffectView` consumers for every
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

        var consumers: [(glass: AdjustableGlassEffectView, hasMain: Bool)] = []
        for cell in Self.mainOnCells {
            for hasMain in [true, false] {
                let glass = AdjustableGlassEffectView(frame: NSRect(
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

        var consumers: [(glass: AdjustableGlassEffectView, hasMain: Bool)] = []
        for cell in Self.mainOnCells {
            for hasMain in [true, false] {
                let glass = AdjustableGlassEffectView(frame: NSRect(
                    x: 0,
                    y: 0,
                    width: probeWidth,
                    height: referenceSide
                ))
                glass.appearance = NSAppearance(
                    named: cell.isLightAppearance ? .aqua : .darkAqua
                )
                GlassMaterialAccess.setVariant(cell.isClear ? 2 : 1, on: glass)
                glass.tintColor = color
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
        guard let contentView = resolvedProbeHostView else { return nil }
        let container = makeClippedContainer()
        contentView.addSubview(container)
        mainProbeContainer = container
        return container
    }

    /// An explicit AppKit island is required when a view controller owns the
    /// window content. Plain AppKit windows without a content-view controller
    /// retain the source-compatible content-view fallback.
    private var resolvedProbeHostView: NSView? {
        guard let hostWindow else { return nil }
        if let probeHostView {
            return probeHostView.window === hostWindow ? probeHostView : nil
        }
        guard hostWindow.contentViewController == nil else { return nil }
        return hostWindow.contentView
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
        try persist(atlas)
    }

    private func persist(_ value: GlassMaterialStyleAtlas) throws {
        guard let storageURL else { return }
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: storageURL, options: .atomic)
    }
}
#endif
