//
//  GlassEffectController.swift
//  LiquidGlassLab
//
//  Product-facing ownership for a configurable HUD material. Products choose
//  semantics; the controller owns atlas loading/calibration, verified
//  participation, parameterized Tint, legacy locking, retries, and fail-closed
//  fallback.
//

#if os(macOS)
import AppKit
import OSLog

@available(macOS 26.0, *)
@MainActor
final class GlassEffectController {
    /// Provenance of the verified base material. On a supported system,
    /// color-specific in-domain Tint matrices are synthesized synchronously;
    /// verified commit-resolved overlays may also be supplied by the
    /// app-scoped runtime cache.
    enum Source: String, Equatable, Sendable {
        case certifiedCatalog
        case runtimeCache
        case runtimeCalibration
    }

    enum Variant: Equatable, Sendable {
        case regular
        case clear
    }

    enum Appearance: Equatable, Sendable {
        case system
        case light
        case dark
    }

    /// Product semantics, deliberately hiding the implementation's window
    /// participation vocabulary.
    enum Emphasis: Equatable, Sendable {
        /// Holds the verified Main-On material even on a never-main HUD.
        case normal
        /// Holds the paired, verified Main-Off material regardless of focus.
        case muted
    }

    struct Configuration: Equatable {
        var variant: Variant
        var visibility: Double
        var appearance: Appearance
        var tint: NSColor?
        var emphasis: Emphasis

        init(
            variant: Variant = .regular,
            visibility: Double = 1,
            appearance: Appearance = .system,
            tint: NSColor? = nil,
            emphasis: Emphasis = .normal
        ) {
            self.variant = variant
            self.visibility = min(max(visibility, 0), 1)
            self.appearance = appearance
            self.tint = tint
            self.emphasis = emphasis
        }

        static func == (
            lhs: Configuration,
            rhs: Configuration
        ) -> Bool {
            lhs.variant == rhs.variant
                && lhs.visibility == rhs.visibility
                && lhs.appearance == rhs.appearance
                && lhs.emphasis == rhs.emphasis
                && Self.colorsMatch(lhs.tint, rhs.tint)
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
    }

    enum FallbackReason: Equatable {
        case calibrationFailed(String)
        case frozenInstallFailed
        case tintNotYetVerified
    }

    /// Live cost of the commit-resolution path, so a perceived delay can be
    /// attributed instead of guessed. Resolution itself measures ~7 ms on the
    /// certification host; anything larger here is orchestration.
    struct TintDiagnostics: Equatable, Sendable {
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
        /// Times the full style transaction ran (base validation + whole-style
        /// write + readback). Should be rare: base changes only.
        var fullFreezeCount: Int = 0
        /// Times only the 20 Tint coefficients were restamped.
        var tintRestampCount: Int = 0
        /// Cost of the most recent install, whichever path it took.
        var lastInstallMilliseconds: Double?
    }

    private(set) var tintDiagnostics = TintDiagnostics()

    enum Status: Equatable {
        case idle
        case waitingForMainWindow
        case calibrating(completed: Int, total: Int)
        case lockingTint
        case ready(source: Source)
        /// The target stays on native glass or its last verified frozen style.
        /// An unverified atlas or tint is never presented as ready.
        case fallback(FallbackReason)
    }

    var configuration: Configuration {
        didSet {
            configuration.visibility = min(
                max(configuration.visibility, 0),
                1
            )
            guard configuration != oldValue else { return }
            let requiresFullMaterialInstall =
                Self.requiresFullMaterialInstall(
                    from: oldValue,
                    to: configuration
                )
            if !Self.colorsMatch(configuration.tint, oldValue.tint) {
                tintConfigurationDidChange(
                    from: oldValue.tint,
                    to: configuration.tint
                )
            }
            if configuration.emphasis != oldValue.emphasis
                || !Self.colorsMatch(configuration.tint, oldValue.tint) {
                resetTintRetryBudget(cancelInFlightCapture: true)
            }
            // A held color is only valid for the emphasis it was verified for,
            // and clearing the tint must clear it outright.
            if configuration.emphasis != oldValue.emphasis
                || configuration.tint == nil {
                lastVerifiedTintColor = nil
            }
            // Materializing probes while the user is already dragging is what
            // made the first out-of-domain drag stutter: nothing can resolve
            // until they are ready. Start that work the moment a tint enters
            // the configuration, so it is over before a drag reaches a color
            // the closed form cannot cover.
            if configuration.tint != nil, oldValue.tint == nil {
                prepareTintCommitResolver()
            }
            if Self.isTintOnlyChange(
                from: oldValue,
                to: configuration
            ) {
                scheduleTintPresentation()
                return
            }
            pendingTintPresentation = false
            applyConfiguration(
                allowsTintRestamp: !requiresFullMaterialInstall
            )
        }
    }

    static func requiresFullMaterialInstall(
        from oldConfiguration: Configuration,
        to newConfiguration: Configuration
    ) -> Bool {
        oldConfiguration.variant != newConfiguration.variant
            || oldConfiguration.appearance != newConfiguration.appearance
            || oldConfiguration.emphasis != newConfiguration.emphasis
    }

    /// Tint is the only continuously streamed configuration axis whose final
    /// layer write is frame-coalesced. Base-material changes still apply
    /// synchronously so geometry and participation never trail their controls.
    static func isTintOnlyChange(
        from oldConfiguration: Configuration,
        to newConfiguration: Configuration
    ) -> Bool {
        oldConfiguration.variant == newConfiguration.variant
            && oldConfiguration.visibility == newConfiguration.visibility
            && oldConfiguration.appearance == newConfiguration.appearance
            && oldConfiguration.emphasis == newConfiguration.emphasis
            && !Self.colorsMatch(
                oldConfiguration.tint,
                newConfiguration.tint
            )
    }

    /// An unresolved Tint may wait only when commit resolution actually
    /// accepted a request. If no request was enqueued, applying is what hands
    /// the held color and status machine back to the bounded legacy capture.
    static func tintPreflightRequiresApply(
        tintIsReady: Bool,
        hasPendingCommitRequest: Bool
    ) -> Bool {
        tintIsReady || !hasPendingCommitRequest
    }

    private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            onStatusChanged?(status)
        }
    }

    var onStatusChanged: ((Status) -> Void)?

    private(set) weak var glassView: AdjustableGlassEffectView?
    private let atlasProvider: GlassMaterialAtlasProvider

    private weak var hostWindow: NSWindow?
    private weak var probeHostView: NSView?
    private var observers: [NSObjectProtocol] = []
    private var installRetryTask: Task<Void, Never>?
    private var calibrationRetryTask: Task<Void, Never>?
    private var tintTask: Task<Void, Never>?
    private var activeTintCaptureGeneration: Int?
    private var tintRetryGeneration = 0
    private var tintRetryIndex = 0
    private var tintCommitResolver: GlassMaterialTintCommitResolver?
    private var tintCommitWarmUpTask: Task<Void, Never>?
    private var tintCommitCache: [
        SIMD3<Double>: [GlassMaterialStyleAtlas.Cell: [Float]]
    ] = [:]
    private var tintCommitCacheOrder: [SIMD3<Double>] = []
    private var pendingTintCommitRequest: (
        color: NSColor,
        sourceColor: GlassMaterialColorValue
    )?
    /// The latest requested Tint has not yet been presented. Color-panel
    /// events can arrive faster than display cadence; keeping one bit here
    /// collapses every intermediate RGB/alpha value into the configuration
    /// already stored above.
    private var pendingTintPresentation = false
    /// A resolver that exhausted the bounded commit path stays disabled until
    /// the next participation recovery or Tint session. This prevents a color
    /// drag from recreating the same persistently failing resolver per RGB.
    private var tintCommitResolutionUnavailable = false
    private var tintCommitFailureCount = 0
    /// The most recent color whose matrices were verified for the current
    /// emphasis. Shown while a newer pick is still resolving, so a continuous
    /// hue drag trails by a turn instead of blinking to untinted glass.
    private var lastVerifiedTintColor: NSColor?
    private var pendingTintCommitRequestedAt: UInt64?
    private var coalescedApplyTask: Task<Void, Never>?
    /// The matrices behind the color currently on screen, pinned outside the
    /// LRU. Letting the cache evict them made the displayed color drop out
    /// mid-drag, because the held-color lookup then found nothing.
    private var displayedTintMatrices: (
        key: SIMD3<Double>,
        matrices: [GlassMaterialStyleAtlas.Cell: [Float]]
    )?
    private var tintDisplayLink: CADisplayLink?
    /// Bumped whenever the provider publishes a different base payload. A
    /// color-only change reuses the base the writer already validated.
    private var baseAtlasGeneration = 0
    private var calibrationRetryIndex = 0
    private var requestedCalibrationAfterInstallFailure = false

    private static let calibrationRetryMilliseconds = [
        1_000, 2_000, 5_000, 10_000, 30_000,
    ]
    private static let tintRetryMilliseconds = [450, 1_000, 2_000, 5_000]
    private static let tintCommitFailureLimit = 3

    convenience init(
        hostWindow: NSWindow?,
        probeHostView: NSView? = nil,
        configuration: Configuration? = nil
    ) {
        self.init(
            hostWindow: hostWindow,
            probeHostView: probeHostView,
            configuration: configuration,
            shortSides: [48, 64, 96, 128, 160, 200, 320],
            storageURL: nil,
            certifiedAtlasURLs: nil
        )
    }

    init(
        hostWindow: NSWindow?,
        probeHostView: NSView? = nil,
        configuration: Configuration?,
        shortSides: [Double] = [48, 64, 96, 128, 160, 200, 320],
        storageURL: URL? = nil,
        certifiedAtlasURLs: [URL]? = nil
    ) {
        self.hostWindow = hostWindow
        self.probeHostView = probeHostView
        self.configuration = configuration ?? Configuration()
        self.atlasProvider = GlassMaterialAtlasProvider(
            hostWindow: hostWindow,
            probeHostView: probeHostView,
            shortSides: shortSides,
            storageURL: storageURL ?? Self.defaultStorageURL(),
            certifiedAtlasURLs: certifiedAtlasURLs
                ?? GlassMaterialAtlasCatalog.bundledAtlasURLs()
        )
        connectProvider()
        observeRecoveryOpportunities()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Attaches product configuration to the owning material view.
    @discardableResult
    func attach(to glassView: AdjustableGlassEffectView) -> Bool {
        if self.glassView !== glassView {
            guard self.glassView?.window == nil else { return false }
            self.glassView?.materialWindowDidChange = nil
            self.glassView?.materialStrength.invalidate()
            resetTintRetryBudget()
        }
        self.glassView = glassView
        glassView.materialWindowDidChange = { [weak self, weak glassView] in
            guard let self, self.glassView === glassView else { return }
            self.applyConfiguration()
        }
        applyConfiguration()
        atlasProvider.ensureCaptured()
        return true
    }

    func invalidate() {
        atlasProvider.invalidate()
        installRetryTask?.cancel()
        installRetryTask = nil
        calibrationRetryTask?.cancel()
        calibrationRetryTask = nil
        calibrationRetryIndex = 0
        resetTintRetryBudget(cancelInFlightCapture: true)
        tintCommitWarmUpTask?.cancel()
        tintCommitWarmUpTask = nil
        coalescedApplyTask?.cancel()
        coalescedApplyTask = nil
        stopTintDisplayLink()
        displayedTintMatrices = nil
        // Probes and the witness window exist only to serve an attached view.
        tintCommitResolver?.invalidate()
        tintCommitResolver = nil
        pendingTintCommitRequest = nil
        pendingTintPresentation = false
        pendingTintCommitRequestedAt = nil
        tintCommitResolutionUnavailable = false
        tintCommitFailureCount = 0
        lastVerifiedTintColor = nil
        tintCommitCache = [:]
        tintCommitCacheOrder = []
        glassView?.materialWindowDidChange = nil
        glassView?.materialStrength.invalidate()
        glassView = nil
        refreshStatus()
    }

    func ensureReady() {
        atlasProvider.ensureCaptured()
        applyConfiguration()
    }

    /// Window room required around the glass's visual bounds so its outer
    /// passes are not clipped by the host window's backing surface.
    ///
    /// The view cannot resize an owning panel itself, so the public
    /// `AdjustableGlassEffectView.requiredWindowInset` forwards this value to
    /// the consumer. Before a verified atlas is available, return the measured
    /// conservative Main-On envelope.
    func requiredWindowInset(
        for size: CGSize,
        respectsRenderExperiment: Bool = true
    ) -> CGFloat {
        if respectsRenderExperiment,
           let margin = glassView?.materialStrength.renderExperiment
            .marginWidthOverride {
            return windowInset(for: margin)
        }
        let shortSide = max(0, min(size.width, size.height))
        let isLight: Bool
        switch configuration.appearance {
        case .light:
            isLight = true
        case .dark:
            isLight = false
        case .system:
            isLight = glassView.map(GlassMaterialStrength.isLightAppearance)
                ?? false
        }
        let cell = GlassMaterialStyleAtlas.Cell(
            isLightAppearance: isLight,
            isClear: configuration.variant == .clear,
            hasMainParticipation: configuration.emphasis == .normal
        )
        if let sample = atlasProvider.atlas.sample(
            for: cell,
            at: Double(shortSide)
        ) {
            return windowInset(for: sample.marginWidth)
        }
        guard configuration.emphasis == .normal else {
            return windowInset(for: 0)
        }
        return windowInset(
            for: atlasProvider.conservativeMainOnMargin(for: shortSide)
        )
    }

    private func windowInset(for marginWidth: Double) -> CGFloat {
        Self.windowInset(
            for: marginWidth,
            osMajorVersion: ProcessInfo.processInfo
                .operatingSystemVersion.majorVersion
        )
    }

    static func windowInset(
        for marginWidth: Double,
        osMajorVersion: Int
    ) -> CGFloat {
        let margin = max(0, marginWidth)
        if margin == 0 {
            return osMajorVersion >= 27 ? 1 : 0
        }
        return ceil(margin) + 1
    }

    func recalibrate() {
        calibrationRetryTask?.cancel()
        calibrationRetryIndex = 0
        atlasProvider.recalibrate()
    }

    // MARK: - Provider

    private func connectProvider() {
        atlasProvider.onStateChanged = { [weak self] _ in
            guard let self else { return }
            self.providerStateDidChange()
        }
        atlasProvider.onAtlasUpdated = { [weak self] _ in
            guard let self else { return }
            self.baseAtlasGeneration += 1
            self.calibrationRetryTask?.cancel()
            self.calibrationRetryIndex = 0
            self.applyConfiguration()
        }
    }

    private func providerStateDidChange() {
        switch atlasProvider.state {
        case .ready:
            calibrationRetryTask?.cancel()
            calibrationRetryIndex = 0
            applyConfiguration()
        case .failed:
            refreshStatus()
            scheduleCalibrationRetry()
        case .idle, .waitingForMainWindow, .capturing:
            refreshStatus()
        }
    }

    // MARK: - Applying product semantics

    // Coalescing configuration updates onto a timer was tried and reverted:
    // while `NSColorPanel` tracks a drag the main runloop runs in event-tracking
    // mode, where a `Task.sleep` continuation does not resume promptly, so
    // applications collapsed to roughly one per second and the color visibly
    // dropped out. Base configuration is therefore applied synchronously;
    // Tint-only changes use the display link registered in common modes.
    private func applyConfiguration(
        allowsTintRestamp: Bool = false
    ) {
        guard let glassView else {
            refreshStatus()
            return
        }
        defer { glassView.updateRequiredWindowInset() }

        glassView.applyControlledConfiguration(
            style: configuration.variant == .clear ? .clear : .regular,
            amount: configuration.visibility
        )

        // Fail closed for Tint: an unverified or hue-suppressed matrix is never
        // presented as the requested color. Colors inside this major's
        // certified domain resolve in this very update; an unknown gamut needs
        // one legal-host commit on the next runloop turn.
        let requestedAtlas = resolvedTintAtlas(
            for: configuration.tint,
            emphasis: configuration.emphasis
        )
        let tintIsReady = configuration.tint == nil
            || (atlasProvider.isPairedCoverageComplete && requestedAtlas != nil)
        if tintIsReady, pendingTintCommitRequest != nil {
            pendingTintCommitRequest = nil
            pendingTintCommitRequestedAt = nil
            tintCommitFailureCount = 0
        }

        var installableAtlas = requestedAtlas
        var displayedTint = tintIsReady ? configuration.tint : nil
        if tintIsReady {
            lastVerifiedTintColor = configuration.tint
        } else if configuration.tint != nil,
                  let heldColor = lastVerifiedTintColor,
                  let heldAtlas = resolvedTintAtlas(
                    for: heldColor,
                    emphasis: configuration.emphasis,
                    scheduleResolutionIfMissing: false
                  ) {
            // Dropping to no tint for that one turn reads as the color blinking
            // out and back while a hue drag streams new colors. Hold the most
            // recently *verified* color instead — still never an unverified
            // matrix, just one turn behind the request.
            installableAtlas = heldAtlas
            displayedTint = heldColor
        }
        // Setting a tint for the first time makes AppKit insert the whole Tint
        // branch into the private tree (five passes become nine). Until that
        // exists, the narrow restamp has no destination and every color falls
        // back to the full transaction — which is what made the first drag
        // after enabling Tint cost tens of milliseconds per color. Request the
        // branch immediately at alpha 0: the coefficient-18 contract makes that
        // visually identical to no tint, so nothing unverified is presented.
        let nativeTint = displayedTint
            ?? configuration.tint?.withAlphaComponent(0)
        glassView.stageMaterialTint(
            nativeColor: nativeTint,
            controlledColor: displayedTint
        )

        guard atlasProvider.isPairedCoverageComplete else {
            refreshStatus()
            atlasProvider.ensureCaptured()
            return
        }

        let hasMainParticipation = configuration.emphasis == .normal
        // When the discrete base axes are unchanged, continuous amount updates
        // are already applied by the strength writer and a color change differs
        // only in 20 Tint coefficients. Restamping that branch preserves the
        // streaming color-picker performance. Appearance, variant, and
        // participation changes never enter this path.
        let installStart = DispatchTime.now().uptimeNanoseconds
        if allowsTintRestamp,
           glassView.materialStrength.restampTintOverlay(
            installableAtlas ?? atlasProvider.atlas,
            baseGeneration: baseAtlasGeneration,
            mainParticipation: hasMainParticipation,
            tintColor: displayedTint
        ) {
            tintDiagnostics.tintRestampCount += 1
            let restampMs = Self.milliseconds(since: installStart)
            tintDiagnostics.lastInstallMilliseconds = restampMs
            if restampMs > 4 {
                GlassMaterialTintLog.signposts.notice(
                    "slow tint restamp \(restampMs, format: .fixed(precision: 1), privacy: .public)ms"
                )
            }
            installRetryTask?.cancel()
            // AppKit can restamp the base Recipe immediately after a Tint
            // matrix write. The pre-commit sentinel repairs that expected
            // transient before presentation, but a synchronous full-style
            // audit here observes the middle of the handoff and falsely
            // reports frozenInstallFailed. The narrow write already proved
            // its own Tint readback; reserve the complete audit for full
            // installs and base-context changes.
            refreshStatus(acceptingSuccessfulTintRestamp: true)
            glassView.materialStrength.requestFrozenStyleAuditAfterPreCommit {
                [weak self] in
                self?.refreshStatus()
            }
            return
        }
        tintDiagnostics.fullFreezeCount += 1
        GlassMaterialTintLog.signposts.notice(
            "full freeze (base generation \(self.baseAtlasGeneration, privacy: .public))"
        )
        let installed = glassView.materialStrength.freeze(
            atlas: installableAtlas ?? atlasProvider.atlas,
            mainParticipation: hasMainParticipation,
            baseGeneration: baseAtlasGeneration,
            appearanceSelection: Self.frozenAppearanceSelection(
                for: configuration.appearance
            )
        )
        let freezeMs = Self.milliseconds(since: installStart)
        tintDiagnostics.lastInstallMilliseconds = freezeMs
        GlassMaterialTintLog.signposts.notice(
            "freeze install \(freezeMs, format: .fixed(precision: 1), privacy: .public)ms installed=\(installed, privacy: .public)"
        )
        if installed,
           glassView.materialStrength.frozenStyleIsCurrentlyApplied {
            installRetryTask?.cancel()
            if configuration.tint != nil, !tintIsReady {
                scheduleTintLock()
            }
            refreshStatus()
        } else {
            status = .fallback(.frozenInstallFailed)
            if installRetryTask == nil {
                scheduleInstallRetry()
            }
        }
    }

    static func frozenAppearanceSelection(
        for appearance: Appearance
    ) -> GlassMaterialStrength.FrozenAppearanceSelection {
        switch appearance {
        case .system:
            .system
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    /// A newly inserted NSGlassEffectView can expose only part of its private
    /// tree for a few layout turns. Treat that as deferred installation, not a
    /// corrupt atlas or a reason for the product to retry manually.
    private func scheduleInstallRetry() {
        installRetryTask?.cancel()
        installRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.installRetryTask = nil }
            for delay in [0, 80, 160, 320, 640, 1_000] {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled,
                      self.glassView?.window != nil
                else { return }
                self.applyConfiguration()
                if case .ready = self.status { return }
                if case .lockingTint = self.status { return }
            }
            guard !Task.isCancelled,
                  !self.requestedCalibrationAfterInstallFailure,
                  self.atlasProvider.atlasSource != .runtimeCalibration
            else { return }
            // A major catalog may survive OS selection while its private
            // destination topology no longer does. After materialization
            // retries are exhausted, discard that candidate and fall back to
            // the provider's full paired runtime calibration exactly once.
            self.requestedCalibrationAfterInstallFailure = true
            self.atlasProvider.recalibrate()
        }
    }

    // MARK: - Tint

    /// Returns the provider Atlas plus the matrices required by the requested
    /// Tint, without mutating or persisting the provider's reusable base.
    ///
    /// Certified macOS majors always prefer the accepted closed form, even if
    /// a legacy runtime cache happens to contain the same RGB. Unsupported
    /// colors or OS majors fall back to a complete captured overlay; partial
    /// coverage stays nil and therefore fail-closed.
    private func resolvedTintAtlas(
        for color: NSColor?,
        emphasis: Emphasis,
        scheduleResolutionIfMissing: Bool = true
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
        // The closed form does not cover this color (it leaves the major's
        // certified gamut) or this OS major. Ask the system itself,
        // synchronously, against warm probes.
        return commitResolvedTintAtlas(
            for: color,
            emphasis: emphasis,
            scheduleResolutionIfMissing: scheduleResolutionIfMissing
        )
    }

    /// Builds the overlay for a color the closed form does not cover, from
    /// matrices this controller has already resolved through the system.
    ///
    /// This is deliberately pure. Resolution itself needs a CA commit, and
    /// committing from inside a configuration update runs nested inside the
    /// attached view's own layout pass, which costs the frozen restamp its
    /// final-writer position — the material then reads back as not applied and
    /// the HUD flickers between frozen and native. Resolution therefore happens
    /// on its own runloop turn in `scheduleTintCommitResolution`, and this only
    /// serves the result.
    private func commitResolvedTintAtlas(
        for color: NSColor?,
        emphasis: Emphasis,
        scheduleResolutionIfMissing: Bool
    ) -> GlassMaterialStyleAtlas? {
        guard let color,
              atlasProvider.isPairedCoverageComplete,
              let sourceColor = GlassMaterialColorValue(color)
        else { return nil }
        guard let matrices = cachedCommitMatrices(for: sourceColor) else {
            guard !tintCommitResolutionUnavailable else { return nil }
            // Only the color the product actually requested may enqueue work.
            // Letting the held-color lookup enqueue too made the resolver
            // ping-pong between the new pick and the color it was still
            // showing, so most picks were superseded before resolving.
            if scheduleResolutionIfMissing {
                scheduleTintCommitResolution(
                    for: color,
                    sourceColor: sourceColor
                )
            }
            return nil
        }

        let hasMainParticipation = emphasis == .normal
        var resolved = atlasProvider.atlas
        // Same discipline as synthesis: this value-semantic copy is only the
        // display candidate. A complete successful resolver result is
        // promoted separately through the Provider persistence seam below;
        // this method itself never makes a temporary copy authoritative.
        resolved.removeAllTintMatrices()
        for (cell, matrix) in matrices {
            resolved.addTintMatrix(
                .init(sourceColor: sourceColor, matrix: matrix),
                for: cell
            )
        }
        // Fail closed: the selected participation must be completely covered.
        let required = [true, false].flatMap { isLight in
            [false, true].map { isClear in
                GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: hasMainParticipation
                )
            }
        }
        guard required.allSatisfy({
            resolved.tintMatrix(for: $0, matching: color) != nil
        }) else { return nil }
        return resolved
    }

    /// Materializes the probe set ahead of need. Safe to call repeatedly: the
    /// resolver keeps one warm-up in flight and reports when it is ready.
    private func prepareTintCommitResolver() {
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
            self.tintDiagnostics.warmUpMilliseconds = Self.milliseconds(
                since: start
            )
            self.tintCommitWarmUpTask = nil
            if warm {
                if let color = self.configuration.tint {
                    resolver.prewarmTintBranch(for: color)
                }
                if self.pendingTintCommitRequest != nil {
                    self.startTintDisplayLink()
                }
            } else if self.hostParticipates {
                self.fallBackFromTintCommitResolution()
            }
            self.scheduleTintPresentation()
        }
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

    /// Resolves one color on its own runloop turn, outside any layout pass,
    /// then re-applies. Materialization of the probe set is the only remaining
    /// wait and happens once.
    /// Requests resolution of one color, serviced by the display link.
    ///
    /// The picker emits hundreds of colors a second while the screen can only
    /// show one per frame, and each resolution costs a few milliseconds of main
    /// thread. Servicing every request starved the work that actually mattered.
    /// A display link is the right clock for this: it ticks once per presented
    /// frame and — unlike a timer continuation — keeps ticking while AppKit
    /// tracks a drag in event-tracking mode.
    private func scheduleTintCommitResolution(
        for color: NSColor,
        sourceColor: GlassMaterialColorValue
    ) {
        let key = Self.rgbKey(for: sourceColor)
        guard !tintCommitResolutionUnavailable else { return }
        let previousKey = pendingTintCommitRequest.map {
            Self.rgbKey(for: $0.sourceColor)
        }
        if previousKey != nil, previousKey != key {
            tintDiagnostics.supersededRequestCount += 1
        }
        if previousKey != key {
            tintDiagnostics.attemptsForLastColor = 0
        }
        pendingTintCommitRequest = (color, sourceColor)
        pendingTintCommitRequestedAt = DispatchTime.now().uptimeNanoseconds
        guard hostParticipates else { return }
        if tintCommitResolver == nil,
           let hostWindow,
           let probeHostView,
           probeHostView.window === hostWindow {
            tintCommitResolver = GlassMaterialTintCommitResolver(
                hostWindow: hostWindow,
                mainProbeHost: probeHostView
            )
        }
        guard let resolver = tintCommitResolver else { return }
        if !resolver.isWarm {
            prepareTintCommitResolver()
            return
        }
        startTintDisplayLink()
    }

    /// All Tint sources share one presentation clock. Certified colors are
    /// synthesized synchronously, cached RGB receives a new coefficient 18,
    /// and unresolved colors enqueue commit resolution; none writes the live
    /// destination more than once per displayed frame.
    private func scheduleTintPresentation() {
        if pendingTintPresentation {
            tintDiagnostics.supersededRequestCount += 1
        }
        pendingTintPresentation = true
        startTintDisplayLink()
    }

    private func startTintDisplayLink() {
        guard tintDisplayLink == nil, let glassView else { return }
        let link = glassView.displayLink(
            target: self,
            selector: #selector(tintDisplayLinkFired(_:))
        )
        // Common modes so the link keeps firing while a drag is tracked.
        link.add(to: .main, forMode: .common)
        tintDisplayLink = link
    }

    private func stopTintDisplayLink() {
        tintDisplayLink?.invalidate()
        tintDisplayLink = nil
    }

    @objc private func tintDisplayLinkFired(_ sender: CADisplayLink) {
        var shouldApply = false
        if pendingTintPresentation {
            pendingTintPresentation = false
            // Preflight is value-only: certified colors synthesize here and
            // cached colors patch coefficient 18 here, while an unresolved
            // color merely creates pendingTintCommitRequest. Do not touch the
            // destination until the final Tint for this tick is known.
            let requestedAtlas = resolvedTintAtlas(
                for: configuration.tint,
                emphasis: configuration.emphasis
            )
            let tintIsReady = configuration.tint == nil
                || (atlasProvider.isPairedCoverageComplete
                    && requestedAtlas != nil)
            shouldApply = Self.tintPreflightRequiresApply(
                tintIsReady: tintIsReady,
                hasPendingCommitRequest: pendingTintCommitRequest != nil
            )
            if tintIsReady {
                pendingTintCommitRequest = nil
                pendingTintCommitRequestedAt = nil
                tintCommitFailureCount = 0
            }
        }
        guard let request = pendingTintCommitRequest else {
            if shouldApply {
                applyConfiguration(allowsTintRestamp: true)
            }
            if !pendingTintPresentation { stopTintDisplayLink() }
            return
        }
        guard let resolver = tintCommitResolver, resolver.canResolveNow else {
            // A request gated on participation or warm-up has no work to do
            // at display cadence. Recovery and warm-up completion already
            // restart this link when resolution can make progress.
            stopTintDisplayLink()
            return
        }
        let start = DispatchTime.now().uptimeNanoseconds
        tintDiagnostics.attemptsForLastColor += 1
        guard let resolution = resolver.resolveMatrices(
            for: request.color,
            sourceColor: request.sourceColor
        ) else {
            tintCommitFailureCount += 1
            guard tintCommitFailureCount
                    >= Self.tintCommitFailureLimit
            else { return }
            GlassMaterialTintLog.signposts.error(
                "commit resolution failed \(self.tintCommitFailureCount, privacy: .public) times; using legacy capture"
            )
            fallBackFromTintCommitResolution()
            applyConfiguration(allowsTintRestamp: true)
            return
        }
        let matrices = resolution.matrices
        tintDiagnostics.lastResolveMilliseconds = Self.milliseconds(since: start)
        tintDiagnostics.resolvedColorCount += 1
        tintCommitFailureCount = 0
        if let requestedAt = pendingTintCommitRequestedAt {
            tintDiagnostics.lastLatencyMilliseconds = Self.milliseconds(
                since: requestedAt
            )
        }
        GlassMaterialTintLog.signposts.notice(
            "resolved in \(self.tintDiagnostics.lastResolveMilliseconds ?? 0, format: .fixed(precision: 1), privacy: .public)ms latency=\(self.tintDiagnostics.lastLatencyMilliseconds ?? 0, format: .fixed(precision: 1), privacy: .public)ms"
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
        applyConfiguration(allowsTintRestamp: true)
        if pendingTintCommitRequest == nil, !pendingTintPresentation {
            stopTintDisplayLink()
        }
    }

    /// Hands Tint to the bounded legacy path and disables this resolver
    /// generation. A participation recovery or a new Tint session may try the
    /// fast path again; a streaming RGB change cannot recreate it immediately.
    private func fallBackFromTintCommitResolution() {
        tintCommitResolutionUnavailable = true
        pendingTintCommitRequest = nil
        pendingTintPresentation = false
        pendingTintCommitRequestedAt = nil
        tintCommitFailureCount = 0
        stopTintDisplayLink()
        tintCommitResolver?.invalidate()
        tintCommitResolver = nil
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

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func rgbKey(
        for sourceColor: GlassMaterialColorValue
    ) -> SIMD3<Double> {
        SIMD3(sourceColor.red, sourceColor.green, sourceColor.blue)
    }

    private func tintConfigurationDidChange(
        from oldColor: NSColor?,
        to newColor: NSColor?
    ) {
        let oldKey = oldColor.flatMap(GlassMaterialColorValue.init).map(
            Self.rgbKey
        )
        let newKey = newColor.flatMap(GlassMaterialColorValue.init).map(
            Self.rgbKey
        )
        if oldKey != newKey {
            tintDiagnostics.attemptsForLastColor = 0
        }
        if newColor == nil {
            tintCommitResolutionUnavailable = false
            pendingTintCommitRequest = nil
            pendingTintCommitRequestedAt = nil
            stopTintDisplayLink()
        }
    }

    static func resolvedTintAtlas(
        _ atlas: GlassMaterialStyleAtlas,
        color: NSColor?,
        emphasis: Emphasis,
        osMajorVersion: Int
    ) -> GlassMaterialStyleAtlas? {
        guard let color else { return atlas }
        let hasMainParticipation = emphasis == .normal
        let cells = [true, false].flatMap { isLight in
            [false, true].map { isClear in
                GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: hasMainParticipation
                )
            }
        }

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

    /// Cheap predicate for status reporting: answers whether the color could be
    /// installed right now without building an Atlas copy and — critically —
    /// without enqueuing resolution work. Doing either here made every status
    /// refresh duplicate the work of the application that triggered it.
    private func tintCoverageIsComplete(
        for color: NSColor?,
        emphasis: Emphasis
    ) -> Bool {
        guard let color else { return true }
        let hasMainParticipation = emphasis == .normal
        let cells = [true, false].flatMap { isLight in
            [false, true].map { isClear in
                GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: hasMainParticipation
                )
            }
        }
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

    private func scheduleTintLock() {
        // The legacy multi-second capture is now the last resort: while commit
        // resolution is warming or has a pending frame request, it would only
        // duplicate the work and contend for a second witness window. A bounded
        // commit failure clears both gates so this path can take over.
        guard tintCommitWarmUpTask == nil,
              pendingTintCommitRequest == nil
        else { return }
        guard tintTask == nil,
              configuration.tint != nil,
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
                  let requestedColor = self.configuration.tint,
                  !self.tintCoverageIsComplete(
                    for: requestedColor,
                    emphasis: self.configuration.emphasis
                  )
            else { return }
            guard self.hostParticipates else {
                self.status = .waitingForMainWindow
                return
            }

            self.tintRetryIndex += 1
            self.activeTintCaptureGeneration = generation
            self.status = .lockingTint
            self.atlasProvider.captureTintMatrices(
                for: requestedColor
            ) { [weak self] success in
                guard let self else { return }
                if self.activeTintCaptureGeneration == generation {
                    self.activeTintCaptureGeneration = nil
                }
                guard generation == self.tintRetryGeneration,
                      Self.colorsMatch(
                        self.configuration.tint,
                        requestedColor
                      )
                else {
                    self.applyConfiguration(allowsTintRestamp: true)
                    return
                }
                if success {
                    self.tintRetryIndex = 0
                }
                self.applyConfiguration(allowsTintRestamp: true)
            }
        }
    }

    private func resetTintRetryBudget(
        cancelInFlightCapture: Bool = false
    ) {
        tintRetryGeneration += 1
        tintRetryIndex = 0
        tintTask?.cancel()
        tintTask = nil
        if cancelInFlightCapture {
            activeTintCaptureGeneration = nil
            atlasProvider.cancelTintCapture()
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

    // MARK: - Recovery and status

    private var hostParticipates: Bool {
        guard let hostWindow else { return false }
        return NSApp.isActive
            && (hostWindow.isMainWindow || hostWindow.isKeyWindow)
    }

    private func observeRecoveryOpportunities() {
        guard let hostWindow else { return }
        let center = NotificationCenter.default
        let events: [(Notification.Name, AnyObject)] = [
            (NSWindow.didBecomeMainNotification, hostWindow),
            (NSWindow.didBecomeKeyNotification, hostWindow),
            (NSWindow.didChangeScreenNotification, hostWindow),
            (NSApplication.didBecomeActiveNotification, NSApp),
            (NSApplication.didChangeScreenParametersNotification, NSApp),
        ]
        for (name, object) in events {
            observers.append(center.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recoveryOpportunityArrived()
                }
            })
        }
    }

    private func recoveryOpportunityArrived() {
        resetTintRetryBudget()
        if hostParticipates {
            tintCommitResolutionUnavailable = false
            tintCommitFailureCount = 0
        }
        // Regaining participation rebuilds the private trees, which drops the
        // probes' Tint branch. Re-materialize it now instead of charging the
        // user's next drag for it.
        if let color = configuration.tint, let resolver = tintCommitResolver {
            if resolver.isWarm {
                resolver.prewarmTintBranch(for: color)
            } else {
                prepareTintCommitResolver()
            }
        }
        atlasProvider.ensureCaptured()
        applyConfiguration()
    }

    private func scheduleCalibrationRetry() {
        guard calibrationRetryTask == nil,
              calibrationRetryIndex
                < Self.calibrationRetryMilliseconds.count
        else { return }
        let delay = Self.calibrationRetryMilliseconds[calibrationRetryIndex]
        calibrationRetryIndex += 1
        calibrationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.calibrationRetryTask = nil
            self.atlasProvider.ensureCaptured()
        }
    }

    private func refreshStatus(
        acceptingSuccessfulTintRestamp: Bool = false
    ) {
        guard glassView != nil else {
            status = .idle
            return
        }
        if activeTintCaptureGeneration == tintRetryGeneration {
            status = .lockingTint
            return
        }
        if let tint = configuration.tint,
           atlasProvider.isPairedCoverageComplete,
           !tintCoverageIsComplete(for: tint, emphasis: configuration.emphasis) {
            guard hostParticipates else {
                status = .waitingForMainWindow
                return
            }
            guard tintRetryIndex < Self.tintRetryMilliseconds.count
                    || tintTask != nil
            else {
                status = .fallback(.tintNotYetVerified)
                return
            }
            status = .lockingTint
            scheduleTintLock()
            return
        }

        switch atlasProvider.state {
        case .idle:
            status = .idle
        case .waitingForMainWindow:
            status = .waitingForMainWindow
        case let .capturing(completed, total):
            status = .calibrating(completed: completed, total: total)
        case .ready:
            guard let glassView else { return }
            if acceptingSuccessfulTintRestamp {
                status = .ready(source: source)
            } else {
                status = glassView.materialStrength.frozenStyleIsCurrentlyApplied
                    ? .ready(source: source)
                    : .fallback(.frozenInstallFailed)
            }
        case let .failed(message):
            status = .fallback(.calibrationFailed(message))
        }
    }

    private var source: Source {
        switch atlasProvider.atlasSource {
        case .certified:
            .certifiedCatalog
        case .cache:
            .runtimeCache
        case .runtimeCalibration, .none:
            .runtimeCalibration
        }
    }

    private static func defaultStorageURL() -> URL? {
        guard let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let appScope = Bundle.main.bundleIdentifier
            ?? ProcessInfo.processInfo.processName
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return cacheRoot
            .appendingPathComponent(appScope, isDirectory: true)
            .appendingPathComponent(
                "AdjustableGlass",
                isDirectory: true
            )
            .appendingPathComponent(
                "runtime-macos-\(major).json",
                isDirectory: false
            )
    }
}
#endif
