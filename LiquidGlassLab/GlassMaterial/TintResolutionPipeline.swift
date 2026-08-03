//
//  TintResolutionPipeline.swift
//  AdjustableGlass
//
//  Package-internal Tint producer for GlassEffectController. The pipeline owns
//  everything that turns a requested color into verified matrices: the source
//  precedence (certified closed-form synthesis, then the exact verified RGB
//  cache, then system commit resolution against warm probes), the bounded
//  failure budget that hands streaming colors to the stable legacy capture
//  path, and the verified-overlay persistence trigger.
//
//  The pipeline never touches the live tree, the frame-coalesced display
//  clock, the held-color presentation policy, or the product status machine.
//  The controller drives progression explicitly: it records the requested
//  Tint through `updateRequestedTint`, enqueues commit work through
//  `requestResolutionIfNeeded`, services it at display cadence through
//  `servicePendingResolution`, and reads a side-effect-free `ResolutionState`
//  snapshot to decide what to install. UI effects the pipeline's own
//  progression must trigger (arming the display clock after warm-up, legacy
//  capture status, re-apply after a capture completes) are reported through
//  callbacks the controller wires to its owned machinery.
//

#if os(macOS)
import AppKit
import OSLog

@available(macOS 26.0, *)
@MainActor
final class TintResolutionPipeline {
    /// Side-effect-free closed state for one requested color. Reading it never
    /// enqueues resolution work, never clears recorded requests, and never
    /// mutates the provider or its caches. Not Equatable: it carries a
    /// `GlassMaterialStyleAtlas`, which is `Codable`/`Sendable` but not
    /// `Equatable`.
    struct ResolutionState {
        /// The color is fully verified for the emphasis: no Tint, or the
        /// certified closed form / exact cache / provider overlay covers it.
        var isReady: Bool
        /// The complete installable overlay for the requested color, or nil
        /// when nothing verified can serve it.
        var installableAtlas: GlassMaterialStyleAtlas?
        /// The color the next install would display, nil for no Tint.
        var displayedColor: NSColor?
        /// Whether commit resolution currently holds a recorded request.
        var hasPendingRequest: Bool
    }

    /// What `requestResolutionIfNeeded` did with the requested color.
    enum RequestOutcome: Equatable {
        /// Already verifiable; nothing was enqueued.
        case covered
        /// Request recorded and a warm resolver can service it now.
        case enqueued
        /// Request recorded; probe warm-up is in flight and the service clock
        /// starts when it completes.
        case warming
        /// Request recorded, but no host-bound resolver machinery can run yet.
        case waitingForHost
        /// The fast path is disabled by the bounded failure budget.
        case unavailable
    }

    /// What one display-cadence `servicePendingResolution` call did.
    enum ServiceOutcome: Equatable {
        /// No request is recorded.
        case idle
        /// A request is recorded but resolution cannot run yet (cold probes or
        /// a nonparticipating host); the owner stops the service clock.
        case waiting
        /// The attempt failed inside the bounded budget; the clock keeps
        /// running for the next frame.
        case failedAttempt
        /// Matrices resolved, cached, pinned, and handed to persistence; the
        /// recorded request was cleared. The owner applies the result.
        case resolved
        /// The bounded budget exhausted the fast path; the pipeline disabled
        /// it and the legacy capture fallback may take over.
        case fellBackToLegacy
    }

    /// Legacy-capture progression steps the owner maps to product status.
    enum LegacyCaptureStep: Equatable {
        /// The bounded capture transaction started.
        case started
        /// The host is not participating; the owner reports waiting.
        case waitingForHost
    }

    /// Resolution-side diagnostics. Install counters stay with the
    /// controller's `TintDiagnostics`; this is the seam it forwards from.
    struct ResolutionDiagnostics: Equatable, Sendable {
        /// Request-to-displayed latency for the most recent resolved color.
        var lastLatencyMilliseconds: Double?
        /// Cost of the resolving commit alone.
        var lastResolveMilliseconds: Double?
        /// One-time probe materialization.
        var warmUpMilliseconds: Double?
        /// Commit attempts the most recent color needed.
        var attemptsForLastColor: Int = 0
        /// Colors resolved through the system this session.
        var resolvedColorCount: Int = 0
        /// Requests coalesced away because a newer pick arrived first.
        var supersededRequestCount: Int = 0
    }

    private(set) var resolutionDiagnostics = ResolutionDiagnostics()

    /// The provider's atlas, paired-coverage gate, persistence seam, and
    /// legacy capture seam back every source in this pipeline.
    private let atlasProvider: GlassMaterialAtlasProvider

    /// The reference host the host-bound resolver is targeted at. Ownership of
    /// the pair stays with the controller; the pipeline is merely informed so
    /// it can rebuild host-bound machinery on rebind.
    private weak var hostWindow: NSWindow?
    private weak var probeHostView: NSView?

    private var tintCommitResolver: GlassMaterialTintCommitResolver?
    private var tintCommitWarmUpTask: Task<Void, Never>?
    /// Exact verified cache, bounded to the atlas's color limit and keyed by
    /// RGB only — the requested alpha is patched into coefficient 18.
    private var tintCommitCache: [
        SIMD3<Double>: [GlassMaterialStyleAtlas.Cell: [Float]]
    ] = [:]
    private var tintCommitCacheOrder: [SIMD3<Double>] = []
    private var pendingTintCommitRequest: (
        color: NSColor,
        sourceColor: GlassMaterialColorValue
    )?
    private var pendingTintCommitRequestedAt: UInt64?
    /// A resolver that exhausted the bounded commit path stays disabled until
    /// the next participation recovery or Tint session. This prevents a color
    /// drag from recreating the same persistently failing resolver per RGB.
    private var tintCommitResolutionUnavailable = false
    private var tintCommitFailureCount = 0
    /// The matrices behind the color currently on screen, pinned outside the
    /// LRU. Letting the cache evict them made the displayed color drop out
    /// mid-drag, because the held-color lookup then found nothing.
    private var displayedTintMatrices: (
        key: SIMD3<Double>,
        matrices: [GlassMaterialStyleAtlas.Cell: [Float]]
    )?

    /// Bounded legacy capture: retry budget, in-flight transaction, and the
    /// generation that rejects stale completions after any budget reset.
    private var tintTask: Task<Void, Never>?
    private var activeTintCaptureGeneration: Int?
    private var tintRetryGeneration = 0
    private var tintRetryIndex = 0

    /// The product's requested Tint and emphasis, recorded through the
    /// explicit request channel. The pipeline never reads the controller's
    /// configuration.
    private var requestedTint: NSColor?
    private var requestedEmphasis: GlassEffectController.Emphasis = .normal

    /// Warm-up completed. The owner prewarms the branch, arms the display
    /// clock when a request is recorded, and reports fallback when warm-up
    /// failed while the host participates.
    var onWarmUpCompleted: ((Bool) -> Void)?
    /// Legacy capture reached a status-relevant step.
    var onLegacyCaptureStep: ((LegacyCaptureStep) -> Void)?
    /// A legacy capture transaction finished; the owner re-applies.
    var onLegacyCaptureCompleted: (() -> Void)?

    private static let tintRetryMilliseconds = [450, 1_000, 2_000, 5_000]
    private static let tintCommitFailureLimit = 3

    init(
        atlasProvider: GlassMaterialAtlasProvider,
        hostWindow: NSWindow? = nil,
        probeHostView: NSView? = nil
    ) {
        self.atlasProvider = atlasProvider
        self.hostWindow = hostWindow
        self.probeHostView = probeHostView
    }

    // MARK: - Explicit request channel

    /// Records the product's requested Tint and emphasis. Resets the per-color
    /// attempt accounting when the RGB changes and tears down request state
    /// when the Tint is cleared — re-arming the fast path for the next Tint
    /// session.
    func updateRequestedTint(
        _ color: NSColor?,
        emphasis: GlassEffectController.Emphasis
    ) {
        defer {
            requestedTint = color
            requestedEmphasis = emphasis
        }
        let oldKey = requestedTint
            .flatMap(GlassMaterialColorValue.init)
            .map(Self.rgbKey)
        let newKey = color
            .flatMap(GlassMaterialColorValue.init)
            .map(Self.rgbKey)
        if oldKey != newKey {
            resolutionDiagnostics.attemptsForLastColor = 0
        }
        if color == nil {
            tintCommitResolutionUnavailable = false
            pendingTintCommitRequest = nil
            pendingTintCommitRequestedAt = nil
        }
    }

    /// Whether a commit resolution request is currently recorded. Drives the
    /// owner's preflight decision: an unresolved Tint may wait only when the
    /// fast path actually accepted the request.
    var hasPendingRequest: Bool {
        pendingTintCommitRequest != nil
    }

    /// Enqueues commit resolution for the requested color when neither the
    /// certified closed form nor the exact verified cache can serve it.
    /// May schedule probe warm-up. The owner arms the service clock on
    /// `.enqueued` and lets `.warming` completion re-arm it.
    @discardableResult
    func requestResolutionIfNeeded() -> RequestOutcome {
        guard let color = requestedTint,
              atlasProvider.isPairedCoverageComplete,
              let sourceColor = GlassMaterialColorValue(color)
        else { return .covered }
        if resolvedTintAtlas(for: color, emphasis: requestedEmphasis) != nil {
            return .covered
        }
        return enqueueCommitResolution(for: color, sourceColor: sourceColor)
    }

    // MARK: - Side-effect-free snapshot

    /// Closed, side-effect-free state for any color — the requested color or a
    /// held last-verified color. Never enqueues work: only
    /// `requestResolutionIfNeeded` may do that.
    func snapshot(
        for color: NSColor?,
        emphasis: GlassEffectController.Emphasis
    ) -> ResolutionState {
        guard let color else {
            return ResolutionState(
                isReady: true,
                installableAtlas: nil,
                displayedColor: nil,
                hasPendingRequest: pendingTintCommitRequest != nil
            )
        }
        let requestedAtlas = resolvedTintAtlas(for: color, emphasis: emphasis)
        let isReady = atlasProvider.isPairedCoverageComplete
            && requestedAtlas != nil
        return ResolutionState(
            isReady: isReady,
            installableAtlas: requestedAtlas,
            displayedColor: isReady ? color : nil,
            hasPendingRequest: pendingTintCommitRequest != nil
        )
    }

    /// Clears the recorded request once the requested color is verifiable.
    /// Resets the bounded failure count so a healthy later request does not
    /// inherit a failed generation's budget.
    func confirmRequestSatisfied() {
        pendingTintCommitRequest = nil
        pendingTintCommitRequestedAt = nil
        tintCommitFailureCount = 0
    }

    /// Cheap predicate answering whether the color could be installed right
    /// now without building an Atlas copy and — critically — without enqueuing
    /// resolution work. Doing either here made every status refresh duplicate
    /// the work of the application that triggered it.
    func isCoverageComplete(
        for color: NSColor?,
        emphasis: GlassEffectController.Emphasis
    ) -> Bool {
        guard let color else { return true }
        let hasMainParticipation = emphasis == .normal
        let cells = Self.tintCells(hasMainParticipation: hasMainParticipation)
        guard let sourceColor = GlassMaterialColorValue(color) else {
            return false
        }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if GlassMaterialTintMatrixSynthesizer.supportedOSMajorVersions
            .contains(major),
           cells.allSatisfy({
               GlassMaterialTintMatrixSynthesizer.matrix(
                   for: sourceColor,
                   cell: $0,
                   osMajorVersion: major
               ) != nil
           }) {
            return true
        }
        if cachedCommitMatrices(for: sourceColor) != nil { return true }
        return cells.allSatisfy {
            atlasProvider.atlas.tintMatrix(for: $0, matching: color) != nil
        }
    }

    // MARK: - Display-cadence progression

    /// Services the recorded commit request exactly once at display cadence.
    /// Resolution ordering is fixed and preserved: resolve, store in the
    /// exact cache, trigger verified-overlay persistence (without an
    /// `onAtlasUpdated` callback), pin the accepted outcome, clear the
    /// recorded request, then report `.resolved` so the owner applies.
    func servicePendingResolution() -> ServiceOutcome {
        guard let request = pendingTintCommitRequest else { return .idle }
        guard let resolver = tintCommitResolver, resolver.canResolveNow else {
            return .waiting
        }
        let start = DispatchTime.now().uptimeNanoseconds
        resolutionDiagnostics.attemptsForLastColor += 1
        guard let resolution = resolver.resolveMatrices(
            for: request.color,
            sourceColor: request.sourceColor
        ) else {
            tintCommitFailureCount += 1
            guard tintCommitFailureCount >= Self.tintCommitFailureLimit
            else { return .failedAttempt }
            GlassMaterialTintLog.signposts.error(
                "commit resolution failed \(self.tintCommitFailureCount, privacy: .public) times; using legacy capture"
            )
            disableFastPath()
            return .fellBackToLegacy
        }
        let matrices = resolution.matrices
        resolutionDiagnostics.lastResolveMilliseconds = Self.milliseconds(
            since: start
        )
        resolutionDiagnostics.resolvedColorCount += 1
        tintCommitFailureCount = 0
        if let requestedAt = pendingTintCommitRequestedAt {
            resolutionDiagnostics.lastLatencyMilliseconds = Self.milliseconds(
                since: requestedAt
            )
        }
        GlassMaterialTintLog.signposts.notice(
            "resolved in \(self.resolutionDiagnostics.lastResolveMilliseconds ?? 0, format: .fixed(precision: 1), privacy: .public)ms latency=\(self.resolutionDiagnostics.lastLatencyMilliseconds ?? 0, format: .fixed(precision: 1), privacy: .public)ms"
        )
        let key = Self.rgbKey(for: request.sourceColor)
        tintCommitResolutionUnavailable = false
        storeCommitMatrices(matrices, for: key)
        if !atlasProvider.persistVerifiedTintMatrices(
            sourceColor: request.sourceColor,
            matrices: matrices,
            captureEnvironment: resolution.environment
        ) {
            GlassMaterialTintLog.signposts.notice(
                "verified Tint overlay was not persisted; retaining session cache"
            )
        }
        displayedTintMatrices = (key, matrices)
        if let newest = pendingTintCommitRequest,
           Self.rgbKey(for: newest.sourceColor) == key {
            pendingTintCommitRequest = nil
        }
        return .resolved
    }

    // MARK: - Warm-up

    /// Materializes the probe set ahead of need. Safe to call repeatedly: the
    /// resolver keeps one warm-up in flight and reports when it is ready.
    func prepareWarmUp() {
        guard atlasProvider.isPairedCoverageComplete || hostParticipates else {
            return
        }
        let resolver = tintCommitResolver ?? {
            guard let hostWindow, let probeHostView,
                  probeHostView.window === hostWindow
            else { return nil }
            let created = GlassMaterialTintCommitResolver(
                hostWindow: hostWindow,
                mainProbeHost: probeHostView
            )
            tintCommitResolver = created
            return created
        }()
        guard let resolver, !resolver.isWarm, tintCommitWarmUpTask == nil
        else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        tintCommitWarmUpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let warm = await resolver.warmUp()
            guard !Task.isCancelled else {
                self.tintCommitWarmUpTask = nil
                return
            }
            self.resolutionDiagnostics.warmUpMilliseconds = Self.milliseconds(
                since: start
            )
            self.tintCommitWarmUpTask = nil
            self.onWarmUpCompleted?(warm)
        }
    }

    /// Materializes the Tint branch ahead of need on an already warm resolver.
    func prewarmTintBranch(for color: NSColor) {
        tintCommitResolver?.prewarmTintBranch(for: color)
    }

    // MARK: - Lifecycle

    /// Re-targets the host-bound resolver at a different reference host
    /// without touching the exact cache, the pinned outcome, or the request.
    /// A replacement host can now resolve what the previous one could not, so
    /// the fast path is re-armed.
    func rebindReferenceHost(
        hostWindow: NSWindow?,
        probeHostView: NSView?
    ) {
        self.hostWindow = hostWindow
        self.probeHostView = probeHostView
        tintCommitWarmUpTask?.cancel()
        tintCommitWarmUpTask = nil
        tintCommitResolver?.invalidate()
        tintCommitResolver = nil
        tintCommitResolutionUnavailable = false
        tintCommitFailureCount = 0
    }

    /// The host regained participation: re-arm the fast path and re-materialize
    /// the resolver's Tint branch, which the participation transition dropped.
    func recoverAfterParticipationGap() {
        if hostParticipates {
            tintCommitResolutionUnavailable = false
            tintCommitFailureCount = 0
        }
        if let color = requestedTint, let resolver = tintCommitResolver {
            if resolver.isWarm {
                resolver.prewarmTintBranch(for: color)
            } else {
                prepareWarmUp()
            }
        }
    }

    /// Stops every producer-owned transaction. The exact cache, the pinned
    /// outcome, and held presentation survive a rebind, but not a teardown.
    func invalidate() {
        resetLegacyCaptureBudget(cancelInFlightCapture: true)
        tintCommitWarmUpTask?.cancel()
        tintCommitWarmUpTask = nil
        tintCommitResolver?.invalidate()
        tintCommitResolver = nil
        pendingTintCommitRequest = nil
        pendingTintCommitRequestedAt = nil
        tintCommitResolutionUnavailable = false
        tintCommitFailureCount = 0
        tintCommitCache = [:]
        tintCommitCacheOrder = []
        displayedTintMatrices = nil
        requestedTint = nil
    }

    // MARK: - Legacy capture fallback

    /// Whether a bounded legacy capture transaction is currently in flight for
    /// the current retry generation.
    var isLegacyCaptureActive: Bool {
        activeTintCaptureGeneration == tintRetryGeneration
    }

    /// Whether the bounded legacy path still has retries — a scheduled task
    /// counts, because it may begin the transaction on its next beat.
    var legacyCaptureHasBudget: Bool {
        tintRetryIndex < Self.tintRetryMilliseconds.count || tintTask != nil
    }

    /// Invalidates the bounded legacy retry budget. `cancelInFlightCapture`
    /// additionally abandons the provider's in-flight capture transaction.
    func resetLegacyCaptureBudget(cancelInFlightCapture: Bool = false) {
        tintRetryGeneration += 1
        tintRetryIndex = 0
        tintTask?.cancel()
        tintTask = nil
        if cancelInFlightCapture {
            activeTintCaptureGeneration = nil
            atlasProvider.cancelTintCapture()
        }
    }

    /// The bounded legacy multi-second capture is the last resort: while
    /// commit resolution is warming or has a pending frame request, it would
    /// only duplicate the work and contend for a second witness window. A
    /// bounded commit failure clears both gates so this path can take over.
    func scheduleLegacyCaptureIfNeeded() {
        guard tintCommitWarmUpTask == nil,
              pendingTintCommitRequest == nil
        else { return }
        guard tintTask == nil,
              let requestedColor = requestedTint,
              activeTintCaptureGeneration == nil,
              tintRetryIndex < Self.tintRetryMilliseconds.count
        else { return }
        let delay = Self.tintRetryMilliseconds[tintRetryIndex]
        let generation = tintRetryGeneration
        tintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self,
                  generation == self.tintRetryGeneration
            else { return }
            self.tintTask = nil
            guard !Task.isCancelled,
                  !self.isCoverageComplete(
                    for: requestedColor,
                    emphasis: self.requestedEmphasis
                  )
            else { return }
            guard self.hostParticipates else {
                self.onLegacyCaptureStep?(.waitingForHost)
                return
            }

            self.tintRetryIndex += 1
            self.activeTintCaptureGeneration = generation
            self.onLegacyCaptureStep?(.started)
            self.atlasProvider.captureTintMatrices(
                for: requestedColor
            ) { [weak self] success in
                guard let self else { return }
                if self.activeTintCaptureGeneration == generation {
                    self.activeTintCaptureGeneration = nil
                }
                // A stale completion — the budget was reset or the request
                // moved on — must not re-arm the retry cadence for the color
                // the capture was actually taken for.
                if generation == self.tintRetryGeneration,
                   Self.colorsMatch(self.requestedTint, requestedColor) {
                    if success {
                        self.tintRetryIndex = 0
                    }
                }
                self.onLegacyCaptureCompleted?()
            }
        }
    }

    /// Hands Tint to the bounded legacy path and disables this resolver
    /// generation. A participation recovery or a new Tint session may try the
    /// fast path again; a streaming RGB change cannot recreate it immediately.
    func disableFastPath() {
        tintCommitResolutionUnavailable = true
        pendingTintCommitRequest = nil
        pendingTintCommitRequestedAt = nil
        tintCommitFailureCount = 0
        tintCommitResolver?.invalidate()
        tintCommitResolver = nil
    }

    // MARK: - Source resolution

    /// Resolves the provider Atlas plus the matrices required by the requested
    /// Tint, without mutating or persisting the provider's reusable base.
    ///
    /// Certified macOS majors always prefer the accepted closed form, even if
    /// a legacy runtime cache happens to contain the same RGB. Unsupported
    /// colors or OS majors fall back to a complete captured overlay; partial
    /// coverage stays nil and therefore fail-closed.
    private func resolvedTintAtlas(
        for color: NSColor?,
        emphasis: GlassEffectController.Emphasis
    ) -> GlassMaterialStyleAtlas? {
        if let resolved = Self.resolvedTintAtlas(
            atlasProvider.atlas,
            color: color,
            emphasis: emphasis,
            osMajorVersion: ProcessInfo.processInfo
                .operatingSystemVersion.majorVersion
        ) {
            return resolved
        }
        return commitResolvedTintAtlas(for: color, emphasis: emphasis)
    }

    /// Builds the overlay for a color the closed form does not cover, from
    /// matrices already resolved through the system.
    ///
    /// This is deliberately pure. Resolution itself needs a CA commit, and
    /// committing from inside a configuration update runs nested inside the
    /// attached view's own layout pass, which costs the frozen restamp its
    /// final-writer position — the material then reads back as not applied and
    /// the HUD flickers between frozen and native. Resolution therefore happens
    /// on its own runloop turn via `servicePendingResolution`, and this only
    /// serves the result.
    private func commitResolvedTintAtlas(
        for color: NSColor?,
        emphasis: GlassEffectController.Emphasis
    ) -> GlassMaterialStyleAtlas? {
        guard let color,
              atlasProvider.isPairedCoverageComplete,
              let sourceColor = GlassMaterialColorValue(color)
        else { return nil }
        guard let matrices = cachedCommitMatrices(for: sourceColor) else {
            return nil
        }

        let hasMainParticipation = emphasis == .normal
        var resolved = atlasProvider.atlas
        // Same discipline as synthesis: this value-semantic copy is only the
        // display candidate. A complete successful resolver result is
        // promoted separately through the Provider persistence seam; this
        // method itself never makes a temporary copy authoritative.
        resolved.removeAllTintMatrices()
        for (cell, matrix) in matrices {
            resolved.addTintMatrix(
                .init(sourceColor: sourceColor, matrix: matrix),
                for: cell
            )
        }
        // Fail closed: the selected participation must be completely covered.
        let required = Self.tintCells(hasMainParticipation: hasMainParticipation)
        guard required.allSatisfy({
            resolved.tintMatrix(for: $0, matching: color) != nil
        }) else { return nil }
        return resolved
    }

    /// Alpha is coefficient 18 exactly and touches nothing else — established
    /// by the fixed-RGB alpha sweep in the accepted Golden fixtures. So the
    /// cache is keyed by RGB and the requested alpha is patched in, which is
    /// what makes dragging an opacity slider cost no resolution at all.
    private func cachedCommitMatrices(
        for sourceColor: GlassMaterialColorValue
    ) -> [GlassMaterialStyleAtlas.Cell: [Float]]? {
        let key = Self.rgbKey(for: sourceColor)
        let entry: [GlassMaterialStyleAtlas.Cell: [Float]]
        if let pinned = displayedTintMatrices, pinned.key == key {
            entry = pinned.matrices
        } else if let cached = tintCommitCache[key] {
            entry = cached
        } else {
            return nil
        }
        var patched: [GlassMaterialStyleAtlas.Cell: [Float]] = [:]
        for (cell, matrix) in entry {
            guard let value = Self.tintMatrixByPatchingAlpha(
                matrix,
                sourceColor: sourceColor
            ) else { return nil }
            patched[cell] = value
        }
        return patched
    }

    private func enqueueCommitResolution(
        for color: NSColor,
        sourceColor: GlassMaterialColorValue
    ) -> RequestOutcome {
        guard !tintCommitResolutionUnavailable else { return .unavailable }
        let key = Self.rgbKey(for: sourceColor)
        let previousKey = pendingTintCommitRequest.map {
            Self.rgbKey(for: $0.sourceColor)
        }
        if previousKey != nil, previousKey != key {
            resolutionDiagnostics.supersededRequestCount += 1
        }
        if previousKey != key {
            resolutionDiagnostics.attemptsForLastColor = 0
        }
        pendingTintCommitRequest = (color, sourceColor)
        pendingTintCommitRequestedAt = DispatchTime.now().uptimeNanoseconds
        guard hostParticipates else { return .waitingForHost }
        if tintCommitResolver == nil,
           let hostWindow,
           let probeHostView,
           probeHostView.window === hostWindow {
            tintCommitResolver = GlassMaterialTintCommitResolver(
                hostWindow: hostWindow,
                mainProbeHost: probeHostView
            )
        }
        guard let resolver = tintCommitResolver else { return .waitingForHost }
        if !resolver.isWarm {
            prepareWarmUp()
            return .warming
        }
        return .enqueued
    }

    private func storeCommitMatrices(
        _ matrices: [GlassMaterialStyleAtlas.Cell: [Float]],
        for key: SIMD3<Double>
    ) {
        if tintCommitCacheOrder.count
            >= GlassMaterialStyleAtlas.tintMatrixColorLimit,
           let oldest = tintCommitCacheOrder.first {
            tintCommitCacheOrder.removeFirst()
            tintCommitCache[oldest] = nil
        }
        tintCommitCacheOrder.removeAll { $0 == key }
        tintCommitCacheOrder.append(key)
        tintCommitCache[key] = matrices
    }

    /// Applies the requested alpha without changing the captured RGB-bound
    /// coefficients. This is the same coefficient-18 contract used by both
    /// the in-memory and persisted Tint overlays.
    static func tintMatrixByPatchingAlpha(
        _ matrix: [Float],
        sourceColor: GlassMaterialColorValue
    ) -> [Float]? {
        guard matrix.count == 20,
              sourceColor.alpha.isFinite,
              sourceColor.alpha >= 0,
              sourceColor.alpha <= 1
        else { return nil }
        var patched = matrix
        patched[18] = Float(sourceColor.alpha)
        return patched
    }

    static func resolvedTintAtlas(
        _ atlas: GlassMaterialStyleAtlas,
        color: NSColor?,
        emphasis: GlassEffectController.Emphasis,
        osMajorVersion: Int
    ) -> GlassMaterialStyleAtlas? {
        guard let color else { return atlas }
        let hasMainParticipation = emphasis == .normal
        let cells = Self.tintCells(hasMainParticipation: hasMainParticipation)

        if GlassMaterialTintMatrixSynthesizer.supportedOSMajorVersions
            .contains(osMajorVersion),
           let sourceColor = GlassMaterialColorValue(color) {
            var parameterized = atlas
            // Do not let an older persisted overlay win over the accepted
            // closed form on the supported major. This copy is never written
            // back to the provider or its cache.
            parameterized.removeAllTintMatrices()
            var matrices: [
                GlassMaterialStyleAtlas.Cell: [Float]
            ] = [:]
            for cell in cells {
                guard let matrix =
                    GlassMaterialTintMatrixSynthesizer.matrix(
                        for: sourceColor,
                        cell: cell,
                        osMajorVersion: osMajorVersion
                    )
                else {
                    matrices = [:]
                    break
                }
                matrices[cell] = matrix
            }
            if matrices.count == cells.count {
                for cell in cells {
                    guard let matrix = matrices[cell] else { return nil }
                    parameterized.addTintMatrix(
                        .init(sourceColor: sourceColor, matrix: matrix),
                        for: cell
                    )
                }
                return parameterized
            }
        }

        guard cells.allSatisfy({
            atlas.tintMatrix(for: $0, matching: color) != nil
        }) else {
            return nil
        }
        return atlas
    }

    // MARK: - Predicates

    private static func tintCells(
        hasMainParticipation: Bool
    ) -> [GlassMaterialStyleAtlas.Cell] {
        [true, false].flatMap { isLight in
            [false, true].map { isClear in
                GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: hasMainParticipation
                )
            }
        }
    }

    private static func colorsMatch(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.isEqual(rhs)
        default:
            false
        }
    }

    private var hostParticipates: Bool {
        guard let hostWindow else { return false }
        return NSApp.isActive
            && (hostWindow.isMainWindow || hostWindow.isKeyWindow)
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func rgbKey(
        for sourceColor: GlassMaterialColorValue
    ) -> SIMD3<Double> {
        SIMD3(sourceColor.red, sourceColor.green, sourceColor.blue)
    }
}
#endif
