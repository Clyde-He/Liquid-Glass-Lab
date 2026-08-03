//
//  MaterialInstallationReconciler.swift
//  AdjustableGlass
//
//  Owns the boundary between an immutable resolved material plan and the
//  AppKit-private destination that must keep presenting it. Resolution and
//  display cadence deliberately live elsewhere.
//

#if os(macOS)
import AppKit
import QuartzCore

@available(macOS 26.0, *)
@MainActor
final class MaterialInstallationReconciler {
    struct CommittedIdentity: Equatable {
        let destination: ObjectIdentifier
        let configuration: GlassEffectController.Configuration
        let baseGeneration: Int
        let displayedTintKey: SIMD3<Double>?
    }

    enum Health: Equatable {
        case uninstalled
        case receiptPending
        case healthy
        case failed
    }

    enum Outcome: Equatable {
        case alreadyCurrent
        case restampedTint
        case installedFull
        case failed
    }

    struct Diagnostics: Equatable {
        var fullFreezeCount = 0
        var tintRestampCount = 0
        var lastInstallMilliseconds: Double?
    }

    private weak var glassView: AdjustableGlassEffectView?
    private var installRetryTask: Task<Void, Never>?
    private var requestedCalibrationAfterInstallFailure = false
    private var pendingIdentity: CommittedIdentity?

    private(set) var committedIdentity: CommittedIdentity?
    private(set) var health: Health = .uninstalled
    private(set) var diagnostics = Diagnostics()

    /// Enforcement events are observations only. The controller decides how
    /// they map to product status; this callback never advances resolution.
    var onHealthChanged: (() -> Void)?
    var onRetryRequested: (() -> Void)?
    var retryShouldStop: (() -> Bool)?
    var shouldRequestRecalibration: (() -> Bool)?
    var onRecalibrationRequested: (() -> Void)?

    func attach(to view: AdjustableGlassEffectView) {
        guard glassView !== view else { return }
        cancelRetry()
        glassView = view
        committedIdentity = nil
        pendingIdentity = nil
        health = .uninstalled
    }

    func invalidate() {
        cancelRetry()
        glassView = nil
        committedIdentity = nil
        pendingIdentity = nil
        health = .uninstalled
        requestedCalibrationAfterInstallFailure = false
    }

    var frozenStyleIsCurrentlyApplied: Bool {
        glassView?.materialStrength.frozenStyleIsCurrentlyApplied == true
    }

    func isAlreadyCurrent(
        plan: ResolvedMaterialPlan,
        configuration: GlassEffectController.Configuration,
        baseGeneration: Int,
        pairedCoverageComplete: Bool
    ) -> Bool {
        guard let glassView else { return false }
        let identityMatches = Self.isAlreadyCurrent(
            committed: committedIdentity,
            destination: ObjectIdentifier(glassView),
            configuration: configuration,
            baseGeneration: baseGeneration,
            displayedTintKey: plan.displayedTintKey,
            pairedCoverageComplete: pairedCoverageComplete,
            liveTreeHoldsPlan: true
        )
        guard identityMatches else { return false }
        let liveTreeHoldsPlan = frozenStyleIsCurrentlyApplied
        guard liveTreeHoldsPlan else {
            setHealth(.failed)
            return false
        }
        setHealth(.healthy)
        return true
    }

    /// Pure identity gate used by the imperative reconciler and exhaustive
    /// tests. A historical receipt is never enough without the live-tree bit.
    static func isAlreadyCurrent(
        committed: CommittedIdentity?,
        destination: ObjectIdentifier,
        configuration: GlassEffectController.Configuration,
        baseGeneration: Int,
        displayedTintKey: SIMD3<Double>?,
        pairedCoverageComplete: Bool,
        liveTreeHoldsPlan: Bool
    ) -> Bool {
        guard let committed else { return false }
        return committed.destination == destination
            && committed.configuration == configuration
            && committed.baseGeneration == baseGeneration
            && committed.displayedTintKey == displayedTintKey
            && pairedCoverageComplete
            && liveTreeHoldsPlan
    }

    /// Reconciles one already-resolved desired plan with the live destination.
    /// This method never asks for Tint resolution, starts probes, or derives
    /// product status. A committed identity is published only after the
    /// corresponding writer transaction and authoritative readback succeed.
    func reconcile(
        plan: ResolvedMaterialPlan,
        configuration: GlassEffectController.Configuration,
        atlas: GlassMaterialStyleAtlas,
        baseGeneration: Int,
        mainParticipation: Bool,
        appearanceSelection: GlassMaterialStrength.FrozenAppearanceSelection,
        allowsTintRestamp: Bool,
        checksCurrentIdentity: Bool
    ) -> Outcome {
        guard let glassView else {
            setHealth(.uninstalled)
            return .failed
        }

        if checksCurrentIdentity, isAlreadyCurrent(
            plan: plan,
            configuration: configuration,
            baseGeneration: baseGeneration,
            pairedCoverageComplete: true
        ) {
            return .alreadyCurrent
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        if allowsTintRestamp,
           glassView.materialStrength.restampTintOverlay(
               atlas,
               baseGeneration: baseGeneration,
               mainParticipation: mainParticipation,
               tintColor: plan.displayedTint
           ) {
            diagnostics.tintRestampCount += 1
            let restampMilliseconds = Self.milliseconds(
                since: startedAt
            )
            diagnostics.lastInstallMilliseconds = restampMilliseconds
            pendingIdentity = Self.makeIdentity(
                for: plan,
                configuration: configuration,
                baseGeneration: baseGeneration,
                destination: glassView
            )
            cancelRetry()
            // Do not emit a strict health event in the middle of the handoff.
            // The successful narrow readback is bridged by the caller for this
            // turn; the post-precommit audit below publishes real health.
            health = .receiptPending
            if restampMilliseconds > 4 {
                GlassMaterialTintLog.signposts.notice(
                    "slow tint restamp \(restampMilliseconds, format: .fixed(precision: 1), privacy: .public)ms"
                )
            }
            glassView.materialStrength.requestFrozenStyleAuditAfterPreCommit {
                [weak self] in
                guard let self else { return }
                if self.frozenStyleIsCurrentlyApplied {
                    if let pendingIdentity = self.pendingIdentity {
                        self.committedIdentity = pendingIdentity
                    }
                    self.pendingIdentity = nil
                    self.setHealth(.healthy, notifying: true)
                } else {
                    self.pendingIdentity = nil
                    self.setHealth(.failed, notifying: true)
                }
            }
            return .restampedTint
        }

        pendingIdentity = nil
        diagnostics.fullFreezeCount += 1
        GlassMaterialTintLog.signposts.notice(
            "full freeze (base generation \(baseGeneration, privacy: .public))"
        )
        let installed = glassView.materialStrength.freeze(
            atlas: atlas,
            mainParticipation: mainParticipation,
            baseGeneration: baseGeneration,
            appearanceSelection: appearanceSelection
        )
        let freezeMilliseconds = Self.milliseconds(
            since: startedAt
        )
        diagnostics.lastInstallMilliseconds = freezeMilliseconds
        GlassMaterialTintLog.signposts.notice(
            "freeze install \(freezeMilliseconds, format: .fixed(precision: 1), privacy: .public)ms installed=\(installed, privacy: .public)"
        )

        guard installed, frozenStyleIsCurrentlyApplied else {
            setHealth(.failed)
            scheduleRetryIfNeeded()
            return .failed
        }

        committedIdentity = Self.makeIdentity(
            for: plan,
            configuration: configuration,
            baseGeneration: baseGeneration,
            destination: glassView
        )
        cancelRetry()
        setHealth(.healthy)
        return .installedFull
    }

    private static func makeIdentity(
        for plan: ResolvedMaterialPlan,
        configuration: GlassEffectController.Configuration,
        baseGeneration: Int,
        destination: AdjustableGlassEffectView
    ) -> CommittedIdentity {
        CommittedIdentity(
            destination: ObjectIdentifier(destination),
            configuration: configuration,
            baseGeneration: baseGeneration,
            displayedTintKey: plan.displayedTintKey
        )
    }

    private func setHealth(
        _ newValue: Health,
        notifying: Bool = false
    ) {
        guard health != newValue else { return }
        health = newValue
        if notifying { onHealthChanged?() }
    }

    private func scheduleRetryIfNeeded() {
        guard installRetryTask == nil else { return }
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
                self.committedIdentity = nil
                self.pendingIdentity = nil
                self.onRetryRequested?()
                if self.retryShouldStop?() == true { return }
            }
            guard !Task.isCancelled,
                  !self.requestedCalibrationAfterInstallFailure,
                  self.shouldRequestRecalibration?() == true
            else { return }
            self.requestedCalibrationAfterInstallFailure = true
            self.onRecalibrationRequested?()
        }
    }

    private func cancelRetry() {
        installRetryTask?.cancel()
        installRetryTask = nil
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
#endif
