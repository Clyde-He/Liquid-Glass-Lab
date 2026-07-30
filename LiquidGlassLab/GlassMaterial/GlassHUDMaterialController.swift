//
//  GlassHUDMaterialController.swift
//  LiquidGlassLab
//
//  Product-facing ownership for a configurable HUD material. Products choose
//  semantics; the controller owns atlas loading/calibration, verified
//  participation, tint locking, retries, and fail-closed fallback.
//

#if os(macOS)
import AppKit

@MainActor
public final class GlassHUDMaterialController {
    /// Provenance of the verified base material. A color-specific tint overlay
    /// may additionally come from the app-scoped runtime cache.
    public enum Source: String, Equatable, Sendable {
        case certifiedCatalog
        case runtimeCache
        case runtimeCalibration
    }

    public enum Variant: Equatable, Sendable {
        case regular
        case clear
    }

    public enum Appearance: Equatable, Sendable {
        case system
        case light
        case dark
    }

    /// Product semantics, deliberately hiding the implementation's window
    /// participation vocabulary.
    public enum Emphasis: Equatable, Sendable {
        /// Holds the verified Main-On material even on a never-main HUD.
        case normal
        /// Holds the paired, verified Main-Off material regardless of focus.
        case muted
    }

    public struct Configuration: Equatable {
        public var variant: Variant
        public var visibility: Double
        public var appearance: Appearance
        public var tint: NSColor?
        public var emphasis: Emphasis

        public init(
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

        public static func == (
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

    public enum FallbackReason: Equatable {
        case calibrationFailed(String)
        case frozenInstallFailed
        case tintNotYetVerified
    }

    public enum Status: Equatable {
        case idle
        case waitingForMainWindow
        case calibrating(completed: Int, total: Int)
        case lockingTint
        case ready(source: Source)
        /// The target stays on native glass or its last verified frozen style.
        /// An unverified atlas or tint is never presented as ready.
        case fallback(FallbackReason)
    }

    public var configuration: Configuration {
        didSet {
            configuration.visibility = min(
                max(configuration.visibility, 0),
                1
            )
            guard configuration != oldValue else { return }
            if configuration.emphasis != oldValue.emphasis
                || !Self.colorsMatch(configuration.tint, oldValue.tint) {
                resetTintRetryBudget(cancelInFlightCapture: true)
            }
            applyConfiguration()
        }
    }

    public private(set) var status: Status = .idle {
        didSet {
            guard status != oldValue else { return }
            onStatusChanged?(status)
        }
    }

    public var onStatusChanged: ((Status) -> Void)?

    public private(set) weak var glassView: GlassMaterialEffectView?
    private let atlasProvider: GlassMaterialAtlasProvider

    private weak var hostWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var installRetryTask: Task<Void, Never>?
    private var calibrationRetryTask: Task<Void, Never>?
    private var tintTask: Task<Void, Never>?
    private var activeTintCaptureGeneration: Int?
    private var tintRetryGeneration = 0
    private var tintRetryIndex = 0
    private var calibrationRetryIndex = 0
    private var requestedCalibrationAfterInstallFailure = false

    private static let calibrationRetryMilliseconds = [
        1_000, 2_000, 5_000, 10_000, 30_000,
    ]
    private static let tintRetryMilliseconds = [450, 1_000, 2_000, 5_000]

    public convenience init(
        hostWindow: NSWindow,
        configuration: Configuration? = nil
    ) {
        self.init(
            hostWindow: hostWindow,
            configuration: configuration,
            shortSides: [48, 64, 96, 128, 160, 200, 320],
            storageURL: nil,
            certifiedAtlasURLs: nil
        )
    }

    init(
        hostWindow: NSWindow,
        configuration: Configuration?,
        shortSides: [Double] = [48, 64, 96, 128, 160, 200, 320],
        storageURL: URL? = nil,
        certifiedAtlasURLs: [URL]? = nil
    ) {
        self.hostWindow = hostWindow
        self.configuration = configuration ?? Configuration()
        self.atlasProvider = GlassMaterialAtlasProvider(
            hostWindow: hostWindow,
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

    /// Attaches product configuration to one material view. Calibration is
    /// lazy but automatic; until verified data is ready the view remains
    /// native and `status` exposes why. Replacing an attached view is accepted
    /// only after the old view has left its window, because AppKit offers no
    /// in-place way to restore a privately authored material tree.
    @discardableResult
    public func attach(to glassView: GlassMaterialEffectView) -> Bool {
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

    /// Stops controlling the attached view after it has been removed from its
    /// window. Returns false and keeps control while the view is still on
    /// screen; silently abandoning a frozen view would leave authored private
    /// material values visible with no controller maintaining them.
    @discardableResult
    public func detach() -> Bool {
        guard glassView?.window == nil else { return false }
        installRetryTask?.cancel()
        installRetryTask = nil
        calibrationRetryTask?.cancel()
        calibrationRetryTask = nil
        calibrationRetryIndex = 0
        resetTintRetryBudget(cancelInFlightCapture: true)
        glassView?.materialWindowDidChange = nil
        glassView?.materialStrength.invalidate()
        glassView = nil
        refreshStatus()
        return true
    }

    public func ensureReady() {
        atlasProvider.ensureCaptured()
        applyConfiguration()
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

    private func applyConfiguration() {
        guard let glassView else {
            refreshStatus()
            return
        }

        glassView.appearance = nsAppearance(for: configuration.appearance)
        glassView.materialStyle = configuration.variant == .clear
            ? .clear
            : .regular
        glassView.materialVisibility = configuration.visibility

        let tintIsReady = tintCoverageIsComplete(
            for: configuration.tint,
            emphasis: configuration.emphasis
        )
        // Fail closed for tint too. A non-main target resolves a hue-suppressed
        // matrix; showing that as the requested tint would falsely report a
        // fully configured material. The tint appears only after its exact RGB
        // has a verified matrix for the selected participation.
        glassView.materialTint = tintIsReady ? configuration.tint : nil

        guard atlasProvider.isPairedCoverageComplete else {
            refreshStatus()
            atlasProvider.ensureCaptured()
            return
        }

        let hasMainParticipation = configuration.emphasis == .normal
        let installed = glassView.materialStrength.freeze(
            atlas: atlasProvider.atlas,
            mainParticipation: hasMainParticipation
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

    private func nsAppearance(for appearance: Appearance) -> NSAppearance? {
        switch appearance {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
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

    private func tintCoverageIsComplete(
        for color: NSColor?,
        emphasis: Emphasis
    ) -> Bool {
        guard let color else { return true }
        let hasMainParticipation = emphasis == .normal
        for isLight in [true, false] {
            for isClear in [false, true] {
                let cell = GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: hasMainParticipation
                )
                guard atlasProvider.atlas.tintMatrix(
                    for: cell,
                    matching: color
                ) != nil else { return false }
            }
        }
        return true
    }

    private func scheduleTintLock() {
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
                    self.applyConfiguration()
                    return
                }
                if success {
                    self.tintRetryIndex = 0
                }
                self.applyConfiguration()
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
        atlasProvider.ensureCaptured()
        if configuration.tint != nil {
            scheduleTintLock()
        }
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

    private func refreshStatus() {
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
            status = glassView.materialStrength.frozenStyleIsCurrentlyApplied
                ? .ready(source: source)
                : .fallback(.frozenInstallFailed)
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
                "GlassHUDMaterial",
                isDirectory: true
            )
            .appendingPathComponent(
                "runtime-macos-\(major).json",
                isDirectory: false
            )
    }
}
#endif
