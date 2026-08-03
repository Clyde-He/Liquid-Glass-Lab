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
    /// Resolution and installation fields are forwarded from their owning
    /// collaborators; the controller retains only the public snapshot.
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
    /// the owner of the display clock, held-color presentation, product
    /// status, and reference-host authority.
    private let tintPipeline: TintResolutionPipeline
    /// Sole authority for committed-plan identity, live destination health,
    /// freeze/restamp installation, and installation retry policy.
    private let installationReconciler = MaterialInstallationReconciler()

    private(set) weak var hostWindow: NSWindow?
    private(set) weak var probeHostView: NSView?
    private var observers: [NSObjectProtocol] = []
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
        installationReconciler.onEnforcementFailure = { [weak self] in
            guard let self else { return }
            let plan = self.buildPlan()
            let outcome = self.reconcileDesiredState(
                plan: plan,
                allowsTintRestamp: false,
                checksCurrentIdentity: true
            )
            self.continueResolutionAfterInstall(outcome, plan: plan)
        }
        installationReconciler.onRetryRequested = { [weak self] in
            guard let self else { return }
            let plan = self.buildPlan()
            let outcome = self.reconcileDesiredState(
                plan: plan,
                allowsTintRestamp: false,
                checksCurrentIdentity: true
            )
            self.continueResolutionAfterInstall(outcome, plan: plan)
        }
        installationReconciler.retryShouldStop = { [weak self] in
            guard let self else { return true }
            if case .ready = self.status { return true }
            if case .lockingTint = self.status { return true }
            return false
        }
        installationReconciler.shouldRequestRecalibration = { [weak self] in
            guard let self else { return false }
            return self.atlasProvider.atlasSource != .runtimeCalibration
        }
        installationReconciler.onRecalibrationRequested = { [weak self] in
            self?.atlasProvider.recalibrate()
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
        }
        self.glassView = glassView
        installationReconciler.attach(to: glassView)
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
        installationReconciler.invalidate()
        calibrationRetryTask?.cancel()
        calibrationRetryTask = nil
        calibrationRetryIndex = 0
        coalescedApplyTask?.cancel()
        coalescedApplyTask = nil
        stopTintDisplayLink()
        tintPipeline.invalidate()
        pendingTintPresentation = false
        lastVerifiedTintColor = nil
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
           let experiment = glassView?.materialStrength.renderExperiment,
           let margin = experiment.windowInsetMarginWidthOverride
            ?? experiment.marginWidthOverride {
            return windowInset(for: margin)
        }
        // Main-Off intentionally suppresses the outer shadow. Some certified
        // atlases retain a small measured margin for the inactive recipe, but
        // that value describes the captured private tree rather than the
        // product's selected no-shadow layout contract. Resolve the muted
        // branch before consulting atlas samples so every supported major uses
        // only the platform safety inset here.
        guard configuration.emphasis == .normal else {
            return windowInset(for: 0)
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
        guard glassView != nil else {
            refreshStatus()
            return
        }
        // A duplicate request — the same configuration over the same verified
        // base, with the same Tint already on screen — needs no install work
        // at all. Consumers can receive duplicate window notifications after
        // their first stable render; re-freezing here is what made HUDs
        // churn their whole material pipeline on reference-host churn.
        //
        // The plan is built before this check so the redundancy key matches
        // what the next install would actually display, and so the status
        // refresh below can still schedule the bounded legacy capture when
        // its pure decision requests recovery: an unresolved Tint that only
        // ever reaches this early return would otherwise stall forever.
        let plan = buildPlan()
        // Resolution progression is independent of installation redundancy.
        // In particular, a warm request whose display clock stopped during a
        // participation gap must be re-armed even when the held/base material
        // is already current. Do not start the fast probe path while a legacy
        // capture transaction owns the same requested color.
        if plan.tintIsReady, plan.hasPendingCommitRequest {
            tintPipeline.confirmRequestSatisfied()
        } else if Self.shouldAdvanceTintResolution(
            tintIsReady: plan.tintIsReady,
            hasLegacyCaptureInFlight: tintPipeline.hasLegacyCaptureInFlight
        ) {
            requestCommitResolutionIfNeeded()
        }
        if installationReconciler.isAlreadyCurrent(
            plan: plan,
            configuration: configuration,
            baseGeneration: baseAtlasGeneration,
            pairedCoverageComplete: atlasProvider.isPairedCoverageComplete
        ) {
            refreshStatus(plan: plan)
            return
        }
        if plan.tintIsReady {
            lastVerifiedTintColor = configuration.tint
        }
        let installOutcome = reconcileDesiredState(
            plan: plan,
            allowsTintRestamp: allowsTintRestamp,
            checksCurrentIdentity: false
        )
        if !atlasProvider.isPairedCoverageComplete {
            atlasProvider.ensureCaptured()
        }
        continueResolutionAfterInstall(installOutcome, plan: plan)
    }

    /// Converges an immutable, already-resolved desired plan with the live
    /// destination. Resolution producers, display cadence, and provider
    /// scheduling are deliberately outside this entry point, so
    /// enforcement callbacks and retry beats cannot accidentally advance the
    /// Tint pipeline.
    @discardableResult
    private func reconcileDesiredState(
        plan: ResolvedMaterialPlan,
        allowsTintRestamp: Bool,
        checksCurrentIdentity: Bool
    ) -> MaterialInstallationReconciler.Outcome {
        guard let glassView else {
            refreshStatus(plan: plan)
            return .failed
        }
        defer { glassView.updateRequiredWindowInset() }

        glassView.applyControlledConfiguration(
            style: configuration.variant == .clear ? .clear : .regular,
            amount: configuration.visibility
        )
        // Setting a tint for the first time makes AppKit insert the whole Tint
        // branch into the private tree. An unresolved color is staged at alpha
        // zero, which materializes the destination without presenting an
        // unverified matrix. Keeping staging inside reconciliation also lets a
        // tree-health retry rebuild a branch AppKit replaced.
        glassView.stageMaterialTint(
            nativeColor: plan.nativeTintColor,
            controlledColor: plan.displayedTint
        )

        guard atlasProvider.isPairedCoverageComplete else {
            refreshStatus(plan: plan)
            return .failed
        }
        let outcome = installationReconciler.reconcile(
            plan: plan,
            configuration: configuration,
            atlas: plan.installableAtlas ?? atlasProvider.atlas,
            baseGeneration: baseAtlasGeneration,
            mainParticipation: configuration.emphasis == .normal,
            appearanceSelection: Self.frozenAppearanceSelection(
                for: configuration.appearance
            ),
            allowsTintRestamp: allowsTintRestamp,
            checksCurrentIdentity: checksCurrentIdentity
        )
        mergePipelineDiagnostics()
        switch outcome {
        case .alreadyCurrent:
            refreshStatus(plan: plan)
        case .restampedTint:
            // A successful Tint readback is a receipt only for this turn. The
            // installation reconciler's post-precommit health event performs
            // the authoritative full audit after the final-writer repair.
            refreshStatus(
                plan: plan,
                acceptingSuccessfulTintRestamp: true
            )
        case .installedFull:
            refreshStatus(plan: plan)
        case .failed:
            status = .fallback(.frozenInstallFailed)
        }
        return outcome
    }

    /// Resolution recovery remains controller-owned and runs only after the
    /// installation boundary has returned a typed outcome.
    private func continueResolutionAfterInstall(
        _ outcome: MaterialInstallationReconciler.Outcome,
        plan: ResolvedMaterialPlan
    ) {
        guard case .installedFull = outcome,
              configuration.tint != nil,
              !plan.tintIsReady
        else { return }
        tintPipeline.scheduleLegacyCaptureIfNeeded()
    }

    /// Fresh, side-effect-free presentation plan for the current
    /// configuration. Built after `servicePendingResolution` has run wherever
    /// the display clock drove the apply, so the install path never reuses
    /// the display preflight snapshot. Reads only pipeline snapshots and the
    /// held last-verified color; it never enqueues resolution work and never
    /// touches the live tree. The held-state input is gathered only when the
    /// requested color is not already verified, so a verified stream never
    /// pays for an atlas copy it cannot use.
    private func buildPlan() -> ResolvedMaterialPlan {
        let requestedState = tintPipeline.snapshot(
            for: configuration.tint,
            emphasis: configuration.emphasis
        )
        let heldState: TintResolutionPipeline.ResolutionState?
        if configuration.tint != nil,
           let heldColor = lastVerifiedTintColor,
           !requestedState.isReady {
            heldState = tintPipeline.snapshot(
                for: heldColor,
                emphasis: configuration.emphasis
            )
        } else {
            heldState = nil
        }
        return ResolvedMaterialPlan.build(
            configuration: configuration,
            baseIsPairedCoverageComplete: atlasProvider
                .isPairedCoverageComplete,
            requestedState: requestedState,
            heldState: heldState,
            lastVerifiedTintColor: lastVerifiedTintColor
        )
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

    /// Resolution and installation are independent axes: an already-current
    /// held/base plan may still need its service clock re-armed. A bounded
    /// legacy capture remains the sole producer while it is active.
    static func shouldAdvanceTintResolution(
        tintIsReady: Bool,
        hasLegacyCaptureInFlight: Bool
    ) -> Bool {
        !tintIsReady && !hasLegacyCaptureInFlight
    }

    /// Forwards collaborator-owned counters into the public diagnostics.
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
        tintDiagnostics.fullFreezeCount = installationReconciler
            .diagnostics.fullFreezeCount
        tintDiagnostics.tintRestampCount = installationReconciler
            .diagnostics.tintRestampCount
        tintDiagnostics.lastInstallMilliseconds = installationReconciler
            .diagnostics.lastInstallMilliseconds
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
        let presentationWasPending = pendingTintPresentation
        pendingTintPresentation = true

        if presentationWasPending {
            presentationSupersededCount += 1
            mergePipelineDiagnostics()
        } else if let glassView {
            // Settle AppKit's pending native Recipe layout before the display-
            // link beat becomes the frozen material's final writer. Leaving
            // this work until CA commit lets a Clear Main-Off restamp land
            // after the Package write during NSColorPanel Value tracking,
            // exposing one native frame. This is glass-tree synchronization,
            // not consumer window geometry; callers must not need an
            // incidental layout to preserve the frozen Main-On contract.
            glassView.needsLayout = true
            glassView.layoutSubtreeIfNeeded()
        }
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
            // Preflight is value-only and derives the ready/unresolved decision
            // through the same plan builder the install path uses, so the
            // duplicated ready/held logic lives in exactly one place. This
            // preflight plan is deliberately not carried into
            // applyConfiguration: `servicePendingResolution` runs in between,
            // so the install consumes a freshly built post-service plan
            // instead. No held-state input is gathered here — the preflight
            // only consumes `tintIsReady` and the pending-request flag, and
            // the held color is not used to decide whether to apply.
            let snapshot = tintPipeline.snapshot(
                for: configuration.tint,
                emphasis: configuration.emphasis
            )
            let plan = ResolvedMaterialPlan.build(
                configuration: configuration,
                baseIsPairedCoverageComplete: atlasProvider
                    .isPairedCoverageComplete,
                requestedState: snapshot,
                heldState: nil,
                lastVerifiedTintColor: lastVerifiedTintColor
            )
            if plan.tintIsReady {
                tintPipeline.confirmRequestSatisfied()
            } else {
                requestCommitResolutionIfNeeded()
            }
            // Evaluate after the explicit request channel ran. An unresolved
            // color accepted by the resolver should wait for that producer;
            // using the pre-request snapshot here would install the held/base
            // material one failure beat earlier than the legacy contract.
            shouldApply = Self.tintPreflightRequiresApply(
                tintIsReady: plan.tintIsReady,
                hasPendingCommitRequest: tintPipeline.hasPendingRequest
            )
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
        plan: ResolvedMaterialPlan? = nil,
        acceptingSuccessfulTintRestamp: Bool = false
    ) {
        mergePipelineDiagnostics()
        // The mapping is pure over an explicit snapshot; the controller
        // gathers the inputs here — the plan (never enqueuing resolution),
        // the pipeline's inert state, the provider state, and the live-tree
        // health read. The pure mapping never schedules; this status owner
        // schedules the bounded legacy capture exactly when the decision
        // requests recovery, so every progression path that lands here —
        // including the redundant-apply early return — keeps an unresolved
        // Tint moving instead of stalling.
        let resolution = StatusMapper.resolve(StatusSnapshot(
            hasView: glassView != nil,
            isLegacyCaptureActive: tintPipeline.isLegacyCaptureActive,
            tintIsUnverified: configuration.tint != nil
                && atlasProvider.isPairedCoverageComplete
                && !(plan ?? buildPlan()).tintIsReady,
            hostParticipates: hostParticipates,
            legacyCaptureHasBudget: tintPipeline.legacyCaptureHasBudget,
            providerState: atlasProvider.state,
            source: source,
            acceptingSuccessfulTintRestamp: acceptingSuccessfulTintRestamp,
            frozenStyleIsCurrentlyApplied: installationReconciler
                .frozenStyleIsCurrentlyApplied
        ))
        status = resolution.status
        if resolution.requestsLegacyCaptureScheduling {
            tintPipeline.scheduleLegacyCaptureIfNeeded()
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
