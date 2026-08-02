//
//  GlassMaterialTintCommitResolver.swift
//  AdjustableGlass
//
//  Synchronous Tint resolution for colors the certified closed form does not
//  cover — for example a gamut beyond Display P3 on macOS 27, P3 on macOS 26,
//  or an OS major that has not been certified yet.
//
//  The accepted `Golden/macOS-26/tint-sync-resolution.json` evidence shows the
//  system resolves the Tint matrix in-process at CA commit: on already
//  materialized probes, the value read immediately after
//  `CATransaction.flush()` is bit-identical to the value the multi-second
//  settle-and-stable-read procedure accepts, and the paired Main-On proof
//  already holds at that instant. So once a probe set is warm, an arbitrary
//  color costs one commit instead of a capture session.
//
//  Two costs remain and are deliberately kept: newly inserted probes need a
//  materialization window before their private trees resolve, and the Main-Off
//  witness must be genuinely nonparticipating. Warm-up is therefore async and
//  one-time; resolution afterwards is synchronous and fails closed.
//

#if os(macOS)
import AppKit
import OSLog
import QuartzCore

/// One shared channel for the Tint path, so a perceived stall reads as a
/// timeline instead of being inferred from a status line. Stream it with:
///
///     log stream --predicate 'subsystem == "design.specos.glasshud"' --debug
///
enum GlassMaterialTintLog {
    static let signposts = Logger(
        subsystem: "design.specos.glasshud",
        category: "tint"
    )
}

private final class GlassMaterialTintWitnessWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@available(macOS 26.0, *)
@MainActor
final class GlassMaterialTintCommitResolver {
    struct Resolution {
        var matrices: [GlassMaterialStyleAtlas.Cell: [Float]]
        var environment: GlassMaterialStyleAtlas.Environment
    }

    private struct ProbePair {
        var mainOnCell: GlassMaterialStyleAtlas.Cell
        var mainOn: NSGlassEffectView
        var mainOff: NSGlassEffectView
    }

    private weak var hostWindow: NSWindow?
    private weak var mainProbeHost: NSView?
    private var mainContainer: NSView?
    private var witnessWindow: GlassMaterialTintWitnessWindow?
    private var witnessContainer: NSView?
    private var pairs: [ProbePair] = []
    private var warmUpTask: Task<Bool, Never>?
    /// The matrices the previous resolution read back, used to detect a commit
    /// that has not yet published the new color instead of tearing the Tint
    /// branch down and rebuilding it every time.
    private var lastResolvedMatrices: [GlassMaterialStyleAtlas.Cell: [Float]] = [:]
    private var lastResolvedSourceColor: GlassMaterialColorValue?

    /// True once probes and witness are materialized and proven, so
    /// `resolveMatrices` can run inside the caller's configuration update.
    private(set) var isWarm = false

    /// Why a resolution could not run, counted so a perceived stall can be
    /// attributed to the exact gate instead of guessed at.
    struct RefusalCounts: Equatable, Sendable {
        var probesCold = 0
        var hostNotParticipating = 0
        var witnessParticipating = 0
        var pairedProofFailed = 0
        var incompleteReadback = 0
        var staleCommit = 0
        var warmUpPolls = 0
    }

    private(set) var refusals = RefusalCounts()

    init(hostWindow: NSWindow, mainProbeHost: NSView) {
        self.hostWindow = hostWindow
        self.mainProbeHost = mainProbeHost
    }

    deinit {
        // Views and windows are owned by the tree we built; releasing the
        // resolver without an explicit teardown must not leak the witness.
        MainActor.assumeIsolated { tearDown() }
    }

    var canResolveNow: Bool {
        isWarm && hostParticipates && witnessIsMainOff
    }

    /// Materializes the probe set once. Returns false when the host is not
    /// genuinely participating, so the caller can keep reporting why.
    func warmUp() async -> Bool {
        if isWarm { return canResolveNow }
        if let warmUpTask { return await warmUpTask.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer { self.warmUpTask = nil }
            return await self.performWarmUp()
        }
        warmUpTask = task
        return await task.value
    }

    private func performWarmUp() async -> Bool {
        guard let hostWindow,
              let mainProbeHost,
              mainProbeHost.window === hostWindow,
              hostParticipates
        else { return false }

        tearDownProbes()
        let container = makeClippedContainer()
        mainProbeHost.addSubview(container)
        mainContainer = container
        guard prepareWitnessWindow(), let witnessContainer else {
            tearDown()
            return false
        }
        pairs = makeProbePairs(
            mainContainer: container,
            witnessContainer: witnessContainer
        )

        GlassMaterialTintLog.signposts.notice(
            "warmUp begin: probes=\(self.pairs.count * 2, privacy: .public)"
        )
        // Materialization needs commits, so commit on every poll turn, and
        // check the proof before sleeping: probes are frequently ready on the
        // first commit and a coarse poll charges a visible wait for work that
        // is already done.
        for attempt in 0..<64 {
            mainProbeHost.layoutSubtreeIfNeeded()
            witnessWindow?.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
            refusals.warmUpPolls += 1
            if hostParticipates, witnessIsMainOff, pairedProofHolds() {
                isWarm = true
                GlassMaterialTintLog.signposts.notice(
                    "warmUp ready after \(attempt + 1, privacy: .public) polls"
                )
                return true
            }
            if attempt % 8 == 0 {
                let participates = hostParticipates
                let witnessOff = witnessIsMainOff
                let proof = pairedProofHolds()
                GlassMaterialTintLog.signposts.notice(
                    "warmUp poll \(attempt, privacy: .public) participates=\(participates, privacy: .public) witnessOff=\(witnessOff, privacy: .public) proof=\(proof, privacy: .public)"
                )
            }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
        GlassMaterialTintLog.signposts.error(
            "warmUp FAILED after 64 polls — probes torn down"
        )
        tearDown()
        return false
    }

    /// One commit, no waiting: set the color, flush, read back, and prove the
    /// participation split still holds. Returns nil — never a partial or
    /// unproven overlay — if anything about that fails.
    func resolveMatrices(
        for color: NSColor,
        sourceColor: GlassMaterialColorValue
    ) -> Resolution? {
        guard !pairs.isEmpty, isWarm else {
            refusals.probesCold += 1
            GlassMaterialTintLog.signposts.notice("resolve refused: probes cold")
            return nil
        }
        guard hostParticipates else {
            refusals.hostNotParticipating += 1
            GlassMaterialTintLog.signposts.notice("resolve refused: host not participating")
            return nil
        }
        guard witnessIsMainOff else {
            refusals.witnessParticipating += 1
            GlassMaterialTintLog.signposts.notice("resolve refused: witness participating")
            return nil
        }
        guard let hostContent = validMainProbeHost else { return nil }

        // Set and commit. Clearing to nil first would be the simple way to be
        // sure a stale matrix is not read back, but setting `tintColor` from nil
        // makes AppKit insert the whole Tint branch (five passes become nine),
        // so clear-then-set rebuilt that topology on all 16 probes for every
        // color — tens of milliseconds each, exactly the cost that showed up on
        // the first drag and again after the window regained main. Staleness is
        // instead detected below, against the previous readback.
        commitTint(color, in: hostContent)

        var matrices: [GlassMaterialStyleAtlas.Cell: [Float]] = [:]
        for pair in pairs {
            let mainOffCell = Self.mainOffCell(for: pair.mainOnCell)
            guard let onStyle = GlassMaterialStyleSample.capture(
                from: pair.mainOn
            ), let offStyle = GlassMaterialStyleSample.capture(
                from: pair.mainOff
            ) else {
                refusals.incompleteReadback += 1
                GlassMaterialTintLog.signposts.notice(
                    "resolve refused: style capture incomplete"
                )
                return nil
            }
            guard GlassMaterialStyleAtlas.verifiesMainOn(
                onStyle,
                against: offStyle
            ) else {
                refusals.pairedProofFailed += 1
                GlassMaterialTintLog.signposts.notice(
                    "resolve refused: paired proof failed"
                )
                return nil
            }
            guard let onMatrix = GlassMaterialStyleAtlas.captureTintMatrix(
                from: pair.mainOn
            ), let offMatrix = GlassMaterialStyleAtlas.captureTintMatrix(
                from: pair.mainOff
            ), onMatrix.matrix.count == 20, offMatrix.matrix.count == 20,
            onMatrix.sourceColor == sourceColor,
            offMatrix.sourceColor == sourceColor
            else {
                refusals.incompleteReadback += 1
                GlassMaterialTintLog.signposts.notice(
                    "resolve refused: matrix readback incomplete"
                )
                return nil
            }
            matrices[pair.mainOnCell] = onMatrix.matrix
            matrices[mainOffCell] = offMatrix.matrix
        }
        guard matrices.count == pairs.count * 2 else { return nil }

        // A commit that has not published yet returns the previous color's
        // matrices. Two colors can legitimately resolve the same matrix only
        // when they are nearly identical, so an identical readback for a
        // materially different color means "not published yet": commit once
        // more and re-read rather than accepting it.
        if let previousColor = lastResolvedSourceColor,
           matrices == lastResolvedMatrices,
           Self.differsMaterially(sourceColor, previousColor) {
            commitTint(color, in: hostContent)
            var retried: [GlassMaterialStyleAtlas.Cell: [Float]] = [:]
            for pair in pairs {
                guard let onMatrix = GlassMaterialStyleAtlas.captureTintMatrix(
                    from: pair.mainOn
                ), let offMatrix = GlassMaterialStyleAtlas.captureTintMatrix(
                    from: pair.mainOff
                ), onMatrix.matrix.count == 20, offMatrix.matrix.count == 20
                else { return nil }
                retried[pair.mainOnCell] = onMatrix.matrix
                retried[Self.mainOffCell(for: pair.mainOnCell)] =
                    offMatrix.matrix
            }
            GlassMaterialTintLog.signposts.notice(
                "resolve: stale commit, re-committed"
            )
            guard retried != lastResolvedMatrices else {
                refusals.staleCommit += 1
                GlassMaterialTintLog.signposts.notice(
                    "resolve refused: still stale after re-commit"
                )
                return nil
            }
            matrices = retried
        }

        lastResolvedMatrices = matrices
        lastResolvedSourceColor = sourceColor
        return Resolution(
            matrices: matrices,
            environment: .current(for: hostWindow?.screen)
        )
    }

    /// Materializes the Tint branch ahead of need, without reading anything
    /// back. Called when the probes are first warmed and again after the host
    /// regains participation, because AppKit rebuilds the private trees across
    /// that transition and drops the branch with them.
    func prewarmTintBranch(for color: NSColor) {
        GlassMaterialTintLog.signposts.notice("prewarm tint branch")
        guard isWarm, !pairs.isEmpty,
              let hostContent = validMainProbeHost
        else { return }
        commitTint(color, in: hostContent)
        lastResolvedMatrices = [:]
        lastResolvedSourceColor = nil
    }

    private func commitTint(_ color: NSColor, in hostContent: NSView) {
        for pair in pairs {
            pair.mainOn.tintColor = color
            pair.mainOff.tintColor = color
        }
        hostContent.layoutSubtreeIfNeeded()
        witnessWindow?.contentView?.layoutSubtreeIfNeeded()
        CATransaction.flush()
    }

    private static func differsMaterially(
        _ lhs: GlassMaterialColorValue,
        _ rhs: GlassMaterialColorValue
    ) -> Bool {
        max(
            abs(lhs.red - rhs.red),
            abs(lhs.green - rhs.green),
            abs(lhs.blue - rhs.blue)
        ) > 0.002
    }

    func invalidate() {
        warmUpTask?.cancel()
        warmUpTask = nil
        tearDown()
    }

    // MARK: - Participation

    private var hostParticipates: Bool {
        guard let hostWindow else { return false }
        return (hostWindow.isMainWindow || hostWindow.isKeyWindow)
            && NSApp.isActive
    }

    private var validMainProbeHost: NSView? {
        guard let hostWindow, let mainProbeHost,
              mainProbeHost.window === hostWindow
        else { return nil }
        return mainProbeHost
    }

    private var witnessIsMainOff: Bool {
        guard let window = witnessWindow else { return false }
        return window.isVisible
            && !window.isMainWindow
            && !window.isKeyWindow
            && NSApp.mainWindow !== window
            && NSApp.keyWindow !== window
    }

    private func pairedProofHolds() -> Bool {
        guard !pairs.isEmpty else { return false }
        return pairs.allSatisfy { pair in
            guard let onStyle = GlassMaterialStyleSample.capture(
                from: pair.mainOn
            ), let offStyle = GlassMaterialStyleSample.capture(
                from: pair.mainOff
            ) else { return false }
            return GlassMaterialStyleAtlas.verifiesMainOn(
                onStyle,
                against: offStyle
            )
        }
    }

    // MARK: - Probe hosts

    private func prepareWitnessWindow() -> Bool {
        if let witnessWindow, witnessContainer != nil {
            witnessWindow.orderFrontRegardless()
            return true
        }
        let frame = hostWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        let window = GlassMaterialTintWitnessWindow(
            contentRect: NSRect(
                x: frame.minX,
                y: frame.minY,
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
        let container = makeClippedContainer()
        content.addSubview(container)
        window.contentView = content
        witnessWindow = window
        witnessContainer = container
        window.orderFrontRegardless()
        return true
    }

    private func tearDownProbes() {
        for pair in pairs {
            pair.mainOn.removeFromSuperview()
            pair.mainOff.removeFromSuperview()
        }
        pairs = []
        mainContainer?.removeFromSuperview()
        mainContainer = nil
        isWarm = false
    }

    private func tearDown() {
        tearDownProbes()
        witnessWindow?.orderOut(nil)
        witnessWindow = nil
        witnessContainer = nil
    }

    private func makeClippedContainer() -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        return container
    }

    private func makeProbePairs(
        mainContainer: NSView,
        witnessContainer: NSView
    ) -> [ProbePair] {
        var pairs: [ProbePair] = []
        for isLight in [true, false] {
            for isClear in [false, true] {
                let mainOnCell = GlassMaterialStyleAtlas.Cell(
                    isLightAppearance: isLight,
                    isClear: isClear,
                    hasMainParticipation: true
                )
                pairs.append(ProbePair(
                    mainOnCell: mainOnCell,
                    mainOn: makeProbe(cell: mainOnCell, in: mainContainer),
                    mainOff: makeProbe(
                        cell: Self.mainOffCell(for: mainOnCell),
                        in: witnessContainer
                    )
                ))
            }
        }
        return pairs
    }

    private func makeProbe(
        cell: GlassMaterialStyleAtlas.Cell,
        in container: NSView
    ) -> NSGlassEffectView {
        let probe = NSGlassEffectView(frame: NSRect(
            x: 0,
            y: 0,
            width: 480,
            height: 200
        ))
        probe.appearance = NSAppearance(
            named: cell.isLightAppearance ? .aqua : .darkAqua
        )
        GlassMaterialAccess.setVariant(cell.isClear ? 2 : 1, on: probe)
        container.addSubview(probe)
        return probe
    }

    private static func mainOffCell(
        for mainOn: GlassMaterialStyleAtlas.Cell
    ) -> GlassMaterialStyleAtlas.Cell {
        GlassMaterialStyleAtlas.Cell(
            isLightAppearance: mainOn.isLightAppearance,
            isClear: mainOn.isClear,
            hasMainParticipation: false
        )
    }
}
#endif
