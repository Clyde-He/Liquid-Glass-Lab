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
    ///
    /// The resolution-side fields are forwarded from the pipeline's
    /// diagnostics; install counters stay controller-owned below.
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
            if configuration.emphasis != oldValue.emphasis
                || !Self.colorsMatch(configuration.tint, oldValue.tint) {
                tintPipeline.updateRequestedTint(
                    configuration.tint,
                    emphasis: configuration.emphasis
                )
                if configuration.tint == nil {
                    stopTintDisplayLink()
                }
                mergePipelineDiagnostics()
                tintPipeline.resetLegacyCaptureBudget(
                    cancelInFlightCapture: true
                )
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
                tintPipeline.prepareWarmUp()
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

    /// Owns every Tint resolution source: certified synthesis precedence, the
    /// verified RGB cache, commit resolution against warm probes, the bounded
    /// legacy capture fallback, and the persistence seam. The controller stays
    /// the owner of the display clock, held-color presentation, installation,
    /// live-tree checks, product status, and reference-host authority.
    private let tintPipeline: TintResolutionPipeline

    private(set) weak var hostWindow: NSWindow?
    private(set) weak var probeHostView: NSView?
    private var observers: [NSObjectProtocol] = []
    private var installRetryTask: Task<Void, Never>?
    private var calibrationRetryTask: Task<Void, Never>?
    /// The latest requested Tint has not yet been presented. Color-panel
    /// events can arrive faster than display cadence; keeping one bit here
    /// collapses every intermediate RGB/alpha value into the configuration
    /// already stored above.
    private var pendingTintPresentation = false
    /// The most recent color whose matrices were verified for the current
    /// emphasis. Shown while a newer pick is still resolving, so a continuous
    /// hue drag trails by a turn instead of blinking to untinted glass.
    private var lastVerifiedTintColor: NSColor?
    private var coalescedApplyTask: Task<Void, Never>?
    private var tintDisplayLink: CADisplayLink?
    /// Presentations coalesced away because a newer one was scheduled before
    /// the previous frame applied. Request-side supersede counts live in the
    /// pipeline; both feed the same public diagnostics counter.
    private var presentationSupersededCount = 0
    /// Bumped whenever the provider publishes a different base payload. A
    /// color-only change reuses the base the writer already validated.
    private var baseAtlasGeneration = 0
    private var calibrationRetryIndex = 0
    private var requestedCalibrationAfterInstallFailure = false

    /// The requested state the last install decided for. Written whenever a
    /// full freeze or narrow Tint restamp accepts the request, so a duplicate
    /// `applyConfiguration` for bit-identical requested and displayed state
    /// can skip the entire install path. The displayed Tint is tracked by
    /// RGB key, not the requested color, so a held last-verified color or a
    /// still-unresolved Tint is not mistaken for a state that needs work.
    private struct AppliedMaterialState {
        var configuration: Configuration
        var baseGeneration: Int
        var displayedTintKey: SIMD3<Double>?
    }

    private var appliedMaterialState: AppliedMaterialState?

    private static let calibrationRetryMilliseconds = [
        1_000, 2_000, 5_000, 10_000, 30_000,
    ]

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
        tintPipeline = TintResolutionPipeline(
            atlasProvider: atlasProvider,
            hostWindow: hostWindow,
            probeHostView: probeHostView
        )
        tintPipeline.updateRequestedTint(
            self.configuration.tint,
            emphasis: self.configuration.emphasis
        )
        tintPipeline.onWarmUpCompleted = { [weak self] warm in
            guard let self else { return }
            self.mergePipelineDiagnostics()
            if warm {
                if let color = self.configuration.tint {
                    self.tintPipeline.prewarmTintBranch(for: color)
                }
                if self.tintPipeline.hasPendingRequest {
                    self.startTintDisplayLink()
                }
            } else if self.hostParticipates {
                self.tintPipeline.disableFastPath()
            }
            self.scheduleTintPresentation()
        }
        tintPipeline.onLegacyCaptureStep = { [weak self] step in
            guard let self else { return }
            switch step {
            case .started:
                self.status = .lockingTint
            case .waitingForHost:
                self.status = .waitingForMainWindow
            }
        }
        tintPipeline.onLegacyCaptureCompleted = { [weak self] in
            self?.applyConfiguration(allowsTintRestamp: true)
        }
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
            tintPipeline.resetLegacyCaptureBudget()
            // The previous install belongs to the old view's tree; the new
            // view must receive the full transaction even for identical
            // requested state.
            appliedMaterialState = nil
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
        coalescedApplyTask?.cancel()
        coalescedApplyTask = nil
        stopTintDisplayLink()
        tintPipeline.invalidate()
        pendingTintPresentation = false
        lastVerifiedTintColor = nil
        appliedMaterialState = nil
        glassView?.materialWindowDidChange = nil
        glassView?.materialStrength.invalidate()
        glassView = nil
        refreshStatus()
    }

    func ensureReady() {
        atlasProvider.ensureCaptured()
        applyConfiguration()
    }

    /// Re-targets calibration and commit resolution at a different reference
    /// host without touching the rendered material.
    ///
    /// A reference host is a calibration/resolver capability, not ownership
    /// of the frozen material: the verified atlas, the installed frozen
    /// style, and every resolved or persisted Tint matrix survive the
    /// transition. Only host-bound machinery is rebuilt — the notification
    /// registrations, the in-flight captures, and the commit resolver, whose
    /// probes live in the previous host's view tree. Returns false when the
    /// effective pair is unchanged, making the call a strict no-op.
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
        observeRecoveryOpportunities()
        tintPipeline.resetLegacyCaptureBudget(cancelInFlightCapture: true)
        tintPipeline.rebindReferenceHost(
            hostWindow: hostWindow,
            probeHostView: probeHostView
        )
        atlasProvider.rebindReferenceHost(
            hostWindow: hostWindow,
            probeHostView: probeHostView
        )
        atlasProvider.ensureCaptured()
        // A replacement host can now resolve what the previous one could not.
        if configuration.tint != nil {
            tintPipeline.prepareWarmUp()
        }
        applyConfiguration()
        return true
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
        // A duplicate request — the same configuration over the same verified
        // base, with the same Tint already on screen — needs no install work
        // at all. Consumers can receive duplicate window notifications after
        // their first stable render; re-freezing here is what made HUDs
        // churn their whole material pipeline on reference-host churn.
        if isRedundantApply() {
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
        // one legal-host commit on the next runloop turn. The snapshot is
        // side-effect-free; only the explicit request channel may enqueue.
        let snapshot = tintPipeline.snapshot(
            for: configuration.tint,
            emphasis: configuration.emphasis
        )
        let tintIsReady = configuration.tint == nil
            || (atlasProvider.isPairedCoverageComplete
                && snapshot.installableAtlas != nil)
        if tintIsReady, snapshot.hasPendingRequest {
            tintPipeline.confirmRequestSatisfied()
        } else if !tintIsReady {
            requestCommitResolutionIfNeeded()
        }

        var installableAtlas = snapshot.installableAtlas
        var displayedTint = snapshot.displayedColor
        if tintIsReady {
            lastVerifiedTintColor = configuration.tint
        } else if configuration.tint != nil,
                  let heldColor = lastVerifiedTintColor,
                  let heldAtlas = tintPipeline.snapshot(
                    for: heldColor,
                    emphasis: configuration.emphasis
                  ).installableAtlas {
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
            appliedMaterialState = AppliedMaterialState(
                configuration: configuration,
                baseGeneration: baseAtlasGeneration,
                displayedTintKey: displayedTint
                    .flatMap(GlassMaterialColorValue.init)
                    .map(Self.rgbKey)
            )
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
        if installed {
            appliedMaterialState = AppliedMaterialState(
                configuration: configuration,
                baseGeneration: baseAtlasGeneration,
                displayedTintKey: displayedTint
                    .flatMap(GlassMaterialColorValue.init)
                    .map(Self.rgbKey)
            )
        }
        if installed,
           glassView.materialStrength.frozenStyleIsCurrentlyApplied {
            installRetryTask?.cancel()
            if configuration.tint != nil, !tintIsReady {
                tintPipeline.scheduleLegacyCaptureIfNeeded()
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
                // The install decision record would otherwise suppress this
                // very retry: the requested state matches the attempt that
                // produced the failed readback. Re-open the install each beat.
                self.appliedMaterialState = nil
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

    /// Enqueues commit resolution for the requested color when neither the
    /// certified closed form nor the exact verified cache can serve it, and
    /// arms the display clock for the outcomes that can make progress.
    /// The pipeline never enqueues on its own; this explicit channel is the
    /// only way work is recorded, and the clock stays controller-owned.
    @discardableResult
    private func requestCommitResolutionIfNeeded()
        -> TintResolutionPipeline.RequestOutcome
    {
        let outcome = tintPipeline.requestResolutionIfNeeded()
        switch outcome {
        case .enqueued:
            startTintDisplayLink()
        case .warming, .waitingForHost, .covered, .unavailable:
            break
        }
        mergePipelineDiagnostics()
        return outcome
    }

    /// Forwards the pipeline's resolution-side counters into the public
    /// diagnostics. Install counters (freeze/restamp counts, install cost)
    /// stay controller-owned and are untouched by the merge.
    private func mergePipelineDiagnostics() {
        tintDiagnostics.lastLatencyMilliseconds = tintPipeline
            .resolutionDiagnostics.lastLatencyMilliseconds
        tintDiagnostics.lastResolveMilliseconds = tintPipeline
            .resolutionDiagnostics.lastResolveMilliseconds
        tintDiagnostics.warmUpMilliseconds = tintPipeline
            .resolutionDiagnostics.warmUpMilliseconds
        tintDiagnostics.attemptsForLastColor = tintPipeline
            .resolutionDiagnostics.attemptsForLastColor
        tintDiagnostics.resolvedColorCount = tintPipeline
            .resolutionDiagnostics.resolvedColorCount
        tintDiagnostics.supersededRequestCount = tintPipeline
            .resolutionDiagnostics.supersededRequestCount
            + presentationSupersededCount
    }

    /// Applies the requested alpha without changing the captured RGB-bound
    /// coefficients. This is the same coefficient-18 contract used by both
    /// the in-memory and persisted Tint overlays.
    static func tintMatrixByPatchingAlpha(
        _ matrix: [Float],
        sourceColor: GlassMaterialColorValue
    ) -> [Float]? {
        TintResolutionPipeline.tintMatrixByPatchingAlpha(
            matrix,
            sourceColor: sourceColor
        )
    }

    /// All Tint sources share one presentation clock. Certified colors are
    /// synthesized synchronously, cached RGB receives a new coefficient 18,
    /// and unresolved colors enqueue commit resolution; none writes the live
    /// destination more than once per displayed frame.
    private func scheduleTintPresentation() {
        if pendingTintPresentation {
            presentationSupersededCount += 1
            mergePipelineDiagnostics()
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
            // color records a request through the pipeline's explicit channel.
            // Do not touch the destination until the final Tint for this tick
            // is known.
            let snapshot = tintPipeline.snapshot(
                for: configuration.tint,
                emphasis: configuration.emphasis
            )
            let tintIsReady = configuration.tint == nil
                || (atlasProvider.isPairedCoverageComplete
                    && snapshot.installableAtlas != nil)
            shouldApply = Self.tintPreflightRequiresApply(
                tintIsReady: tintIsReady,
                hasPendingCommitRequest: snapshot.hasPendingRequest
            )
            if tintIsReady {
                tintPipeline.confirmRequestSatisfied()
            } else {
                requestCommitResolutionIfNeeded()
            }
            mergePipelineDiagnostics()
        }
        // Service pipeline progression in the fixed order: resolve, store in
        // the exact cache, trigger verified-overlay persistence (without an
        // onAtlasUpdated callback), pin the accepted outcome, clear the
        // recorded request — then the side-effect-free snapshot above decides
        // the apply.
        let outcome = tintPipeline.servicePendingResolution()
        switch outcome {
        case .resolved, .fellBackToLegacy:
            shouldApply = true
        case .waiting:
            // A request gated on participation or warm-up has no work to do
            // at display cadence. Recovery and warm-up completion already
            // restart this link when resolution can make progress.
            stopTintDisplayLink()
            return
        case .idle, .failedAttempt:
            break
        }
        mergePipelineDiagnostics()
        guard shouldApply else {
            if !pendingTintPresentation, !tintPipeline.hasPendingRequest {
                stopTintDisplayLink()
            }
            return
        }
        applyConfiguration(allowsTintRestamp: true)
        if !pendingTintPresentation, !tintPipeline.hasPendingRequest {
            stopTintDisplayLink()
        }
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func rgbKey(
        for sourceColor: GlassMaterialColorValue
    ) -> SIMD3<Double> {
        SIMD3(sourceColor.red, sourceColor.green, sourceColor.blue)
    }

    static func resolvedTintAtlas(
        _ atlas: GlassMaterialStyleAtlas,
        color: NSColor?,
        emphasis: Emphasis,
        osMajorVersion: Int
    ) -> GlassMaterialStyleAtlas? {
        TintResolutionPipeline.resolvedTintAtlas(
            atlas,
            color: color,
            emphasis: emphasis,
            osMajorVersion: osMajorVersion
        )
    }

    /// True when the last successful install already covers this exact
    /// request: identical configuration, identical verified base, complete
    /// paired coverage, the same Tint that would be displayed now — held or
    /// resolved — already written, and the frozen style still physically
    /// installed on the AppKit tree. The live-tree read is what keeps the
    /// skip safe: the applied record is historical, and AppKit can rebuild
    /// or drop the private tree while every requested axis stays identical.
    /// Without the readback, an early return would strand the HUD on the
    /// system material with `frozenInstallFailed` and no retry. This check
    /// never enqueues resolution work.
    private func isRedundantApply() -> Bool {
        guard let applied = appliedMaterialState,
              applied.configuration == configuration,
              applied.baseGeneration == baseAtlasGeneration,
              atlasProvider.isPairedCoverageComplete,
              glassView?.materialStrength.frozenStyleIsCurrentlyApplied == true
        else { return false }
        return applied.displayedTintKey == displayedTintKeyForCurrentState
    }

    /// The Tint the next install would put on screen, by RGB key, or nil for
    /// no Tint. Mirrors the `displayedTint` decision without enqueuing
    /// resolution: the requested color when it is already verifiable, else
    /// the held last-verified color, else nothing.
    private var displayedTintKeyForCurrentState: SIMD3<Double>? {
        guard let tint = configuration.tint else { return nil }
        if tintPipeline.isCoverageComplete(
            for: tint,
            emphasis: configuration.emphasis
        ) {
            return GlassMaterialColorValue(tint).map(Self.rgbKey)
        }
        guard let held = lastVerifiedTintColor,
              let source = GlassMaterialColorValue(held)
        else { return nil }
        return Self.rgbKey(for: source)
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
        tintPipeline.resetLegacyCaptureBudget()
        tintPipeline.recoverAfterParticipationGap()
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
        mergePipelineDiagnostics()
        guard glassView != nil else {
            status = .idle
            return
        }
        if tintPipeline.isLegacyCaptureActive {
            status = .lockingTint
            return
        }
        if let tint = configuration.tint,
           atlasProvider.isPairedCoverageComplete,
           !tintPipeline.isCoverageComplete(
               for: tint,
               emphasis: configuration.emphasis
           ) {
            guard hostParticipates else {
                status = .waitingForMainWindow
                return
            }
            guard tintPipeline.legacyCaptureHasBudget else {
                status = .fallback(.tintNotYetVerified)
                return
            }
            status = .lockingTint
            tintPipeline.scheduleLegacyCaptureIfNeeded()
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
