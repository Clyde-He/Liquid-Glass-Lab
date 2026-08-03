//
//  ResolvedMaterialPlan.swift
//  AdjustableGlass
//
//  Step 2 of decoupling material resolution from the product controller: the
//  single, source-neutral presentation decision consumed by installation and
//  status. Everything the controller needs to know about a requested Tint —
//  whether it is verified, which color the next install displays, what is
//  staged on the native branch, and the RGB key that identifies that color —
//  is derived here, from the configuration, the provider's base snapshot, the
//  side-effect-free pipeline snapshot, and the controller-held last verified
//  color.
//
//  The plan deliberately carries no source policy, tasks, caches, host or
//  probe references, live-tree state, install receipts, install kind, retry
//  policy, or product status. It is an immutable pure value: `build` reads
//  only its arguments, never enqueues resolution work, and never touches the
//  live tree. It is not Equatable over the atlas it carries.
//

#if os(macOS)
import AppKit

/// The install-relevant presentation decision for one configuration.
@available(macOS 26.0, *)
struct ResolvedMaterialPlan {
    /// How the requested Tint presents. Derived here and nowhere else.
    enum TintPresentation: Equatable {
        /// No Tint requested; nothing is displayed and nothing is staged.
        case none
        /// The requested color is verified and is what the next install
        /// displays.
        case ready
        /// The requested color is not yet verified; the last verified color
        /// is held and displayed instead.
        case held
        /// Neither the requested color nor any held color is verified;
        /// nothing Tint-related is displayed.
        case unresolved
    }

    /// Whether the requested Tint is verified for its emphasis. A nil Tint
    /// is trivially ready.
    let tintIsReady: Bool

    /// The presentation class of the requested Tint.
    let presentation: TintPresentation

    /// Whether commit resolution currently holds a recorded request for the
    /// requested color, forwarded from the pipeline snapshot.
    let hasPendingCommitRequest: Bool

    /// The complete installable overlay for what the next install displays,
    /// or nil when nothing verified can serve it (or no Tint is requested).
    let installableAtlas: GlassMaterialStyleAtlas?

    /// The color the next install displays: the requested color when ready,
    /// the held last-verified color when held, nil otherwise.
    let displayedTint: NSColor?

    /// The color staged on the native Tint branch: the displayed color, or
    /// the requested color at alpha 0 when nothing verified can display.
    let nativeTintColor: NSColor?

    /// The RGB key of `displayedTint`, nil when nothing is displayed. The
    /// key, not the color, is what the redundant-apply record compares.
    let displayedTintKey: SIMD3<Double>?

    /// Derives the presentation decision. Pure: reads only its arguments,
    /// never enqueues resolution work, and never touches the live tree.
    ///
    /// The controller supplies the side-effect-free pipeline snapshots; a
    /// held-state snapshot is only required — and only consulted — when a
    /// last-verified color could serve an unresolved request.
    @MainActor
    static func build(
        configuration: GlassEffectController.Configuration,
        baseIsPairedCoverageComplete: Bool,
        requestedState: TintResolutionPipeline.ResolutionState,
        heldState: TintResolutionPipeline.ResolutionState?,
        lastVerifiedTintColor: NSColor?
    ) -> ResolvedMaterialPlan {
        let tint = configuration.tint
        let tintIsReady: Bool
        if tint == nil {
            tintIsReady = true
        } else {
            tintIsReady = baseIsPairedCoverageComplete
                && requestedState.installableAtlas != nil
        }

        let presentation: TintPresentation
        let installableAtlas: GlassMaterialStyleAtlas?
        let displayedTint: NSColor?
        if tint == nil {
            presentation = .none
            installableAtlas = nil
            displayedTint = nil
        } else if tintIsReady {
            presentation = .ready
            installableAtlas = requestedState.installableAtlas
            displayedTint = tint
        } else if let heldColor = lastVerifiedTintColor,
                  let heldState,
                  let heldAtlas = heldState.installableAtlas {
            presentation = .held
            installableAtlas = heldAtlas
            displayedTint = heldColor
        } else {
            presentation = .unresolved
            installableAtlas = nil
            displayedTint = nil
        }

        let nativeTintColor = displayedTint
            ?? tint?.withAlphaComponent(0)
        let displayedTintKey = displayedTint
            .flatMap(GlassMaterialColorValue.init)
            .map(TintResolutionPipeline.rgbKey)

        return ResolvedMaterialPlan(
            tintIsReady: tintIsReady,
            presentation: presentation,
            hasPendingCommitRequest: requestedState.hasPendingRequest,
            installableAtlas: installableAtlas,
            displayedTint: displayedTint,
            nativeTintColor: nativeTintColor,
            displayedTintKey: displayedTintKey
        )
    }
}

/// Explicit, pure input snapshot for the product status mapping. The
/// controller gathers every field; the mapping itself never reads the
/// pipeline, the provider, the live tree, or the host.
@available(macOS 26.0, *)
struct StatusSnapshot: Equatable {
    var hasView: Bool
    var isLegacyCaptureActive: Bool
    /// The requested Tint exists, the base is verified, and the Tint has no
    /// verified matrix for the current emphasis.
    var tintIsUnverified: Bool
    var hostParticipates: Bool
    var legacyCaptureHasBudget: Bool
    var providerState: GlassMaterialAtlasProvider.State
    var source: GlassEffectController.Source
    var acceptingSuccessfulTintRestamp: Bool
    var frozenStyleIsCurrentlyApplied: Bool
}

/// What the pure status mapping decided, for the controller to apply.
@available(macOS 26.0, *)
struct StatusResolution: Equatable {
    let status: GlassEffectController.Status

    /// Whether the owner must schedule the bounded legacy capture to make
    /// progress. The pure mapping never schedules; the controller's status
    /// owner acts on this flag — including from the redundant-apply early
    /// return, which would otherwise stall an unresolved Tint forever.
    let requestsLegacyCaptureScheduling: Bool
}

/// Pure product-status mapping. Preserves the exact precedence: no view →
/// idle; capture active → locking; unresolved Tint with no participating host
/// → waiting; unresolved with no capture budget → tint fallback; unresolved
/// with budget → locking (and a recovery request); then the provider state;
/// ready requires the one-turn successful-restamp receipt or live-tree
/// frozen-style health.
@available(macOS 26.0, *)
enum StatusMapper {
    static func resolve(_ snapshot: StatusSnapshot) -> StatusResolution {
        guard snapshot.hasView else {
            return StatusResolution(
                status: .idle,
                requestsLegacyCaptureScheduling: false
            )
        }
        if snapshot.isLegacyCaptureActive {
            return StatusResolution(
                status: .lockingTint,
                requestsLegacyCaptureScheduling: false
            )
        }
        if snapshot.tintIsUnverified {
            guard snapshot.hostParticipates else {
                return StatusResolution(
                    status: .waitingForMainWindow,
                    requestsLegacyCaptureScheduling: false
                )
            }
            guard snapshot.legacyCaptureHasBudget else {
                return StatusResolution(
                    status: .fallback(.tintNotYetVerified),
                    requestsLegacyCaptureScheduling: false
                )
            }
            return StatusResolution(
                status: .lockingTint,
                requestsLegacyCaptureScheduling: true
            )
        }
        switch snapshot.providerState {
        case .idle:
            return StatusResolution(
                status: .idle,
                requestsLegacyCaptureScheduling: false
            )
        case .waitingForMainWindow:
            return StatusResolution(
                status: .waitingForMainWindow,
                requestsLegacyCaptureScheduling: false
            )
        case let .capturing(completed, total):
            return StatusResolution(
                status: .calibrating(completed: completed, total: total),
                requestsLegacyCaptureScheduling: false
            )
        case .ready:
            let isReady = snapshot.acceptingSuccessfulTintRestamp
                || snapshot.frozenStyleIsCurrentlyApplied
            return StatusResolution(
                status: isReady
                    ? .ready(source: snapshot.source)
                    : .fallback(.frozenInstallFailed),
                requestsLegacyCaptureScheduling: false
            )
        case let .failed(message):
            return StatusResolution(
                status: .fallback(.calibrationFailed(message)),
                requestsLegacyCaptureScheduling: false
            )
        }
    }
}
#endif
