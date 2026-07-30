//
//  GlassLabTintSyncResolution.swift
//  LiquidGlassLab
//
//  Bench: does the Tint matrix resolve synchronously at CA commit under
//  genuine Main-On participation? The exploratory measurement that motivated
//  this ran on a plain CLI binary, which can never become main or key, so it
//  could only observe the suppressed branch. This experiment repeats it inside
//  the bundled app with a real active host window and a nonparticipating
//  witness, and compares the value read immediately after
//  `CATransaction.flush()` against the value the settled stable-read
//  procedure accepts for the same probe.
//
//  A pass means product Tint no longer needs a multi-second lock: the system
//  computes the matrix in-process, so any color in any gamut can be resolved
//  in one commit instead of captured over several seconds.
//

#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

private final class GlassLabTintSyncWitnessWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct GlassLabTintSyncResolutionRow: Codable, Sendable {
    var colorID: String
    var sourceColor: GlassMaterialColorValue
    /// Whether every requested component sits inside the certified
    /// synthesis domain. Out-of-domain rows are the point of the experiment.
    var isInCertifiedDomain: Bool
    var cell: GlassLabTintSweepCell
    /// Read immediately after `layout` + `CATransaction.flush()`.
    var flushMatrix: [Float]?
    /// Read after the ordinary settle plus consecutive-stable-read procedure.
    var settledMatrix: [Float]?
    var maximumDifference: Double?
    /// Whether the paired Main-On proof held at flush time.
    var pairedProofAtFlush: Bool
    var pairedProofWhenSettled: Bool
    var passed: Bool
    var failure: String?
}

struct GlassLabTintSyncTiming: Codable, Sendable {
    var colorID: String
    /// Two commits: clear-and-flush, then set-and-flush.
    var clearFlushMilliseconds: Double
    var setFlushMilliseconds: Double
    /// Reading the 16 tint matrices back off the private trees.
    var matrixReadbackMilliseconds: Double
    /// Full paired style capture plus `verifiesMainOn` for all eight pairs —
    /// what the product resolver currently repeats for every color.
    var pairedProofMilliseconds: Double
    var totalMilliseconds: Double
}

struct GlassLabTintSyncResolutionDocument: Codable, Sendable {
    var formatVersion: Int
    var capturedAt: String
    var operatingSystem: String
    var environment: GlassLabTintParameterizationSweepDocument.Environment
    var rows: [GlassLabTintSyncResolutionRow]
    var timings: [GlassLabTintSyncTiming]
    var passed: Bool

    var report: String {
        let compared = rows.filter { $0.maximumDifference != nil }
        let worst = compared.compactMap(\.maximumDifference).max() ?? 0
        let outOfDomain = compared.filter { !$0.isInCertifiedDomain }
        let worstOutOfDomain = outOfDomain
            .compactMap(\.maximumDifference).max() ?? 0
        return [
            "== Tint Synchronous Resolution ==",
            "Rows: \(rows.count) · compared: \(compared.count)",
            "Passed: \(rows.filter(\.passed).count)/\(rows.count)",
            "Worst flush-vs-settled difference: \(worst)",
            "Out-of-domain rows: \(outOfDomain.count) · worst: "
                + "\(worstOutOfDomain)",
            "Paired proof at flush: "
                + "\(rows.filter(\.pairedProofAtFlush).count)/\(rows.count)",
            "-- per-color cost (ms) --",
        ].joined(separator: "\n")
            + "\n"
            + timings.map {
                String(
                    format: "%-16s clearFlush %6.1f  setFlush %6.1f  "
                        + "readback %6.1f  pairedProof %6.1f  total %6.1f",
                    ($0.colorID as NSString).utf8String!,
                    $0.clearFlushMilliseconds,
                    $0.setFlushMilliseconds,
                    $0.matrixReadbackMilliseconds,
                    $0.pairedProofMilliseconds,
                    $0.totalMilliseconds
                )
            }.joined(separator: "\n")
    }

    var failureReport: String {
        let failures = rows.filter { !$0.passed }
        guard !failures.isEmpty else { return "No failures." }
        return failures.map {
            "FAIL \($0.colorID) \($0.cell): "
                + ($0.failure ?? "unspecified")
        }.joined(separator: "\n")
    }
}

extension GlassLabView {
    /// Colors chosen to separate the two questions: in-domain colors check
    /// that a flush read agrees with today's accepted procedure, and P3
    /// colors (which leave the certified domain once converted to extended
    /// sRGB) check that the system resolver covers what synthesis cannot.
    private static var tintSyncResolutionColors: [GlassLabTintSweepColor] {
        func color(
            _ id: String,
            _ nsColor: NSColor,
            alpha: Double = 0.8
        ) -> GlassLabTintSweepColor? {
            guard let value = GlassMaterialColorValue(
                nsColor.withAlphaComponent(alpha)
            ) else { return nil }
            return GlassLabTintSweepColor(
                id: id,
                label: id,
                red: value.red,
                green: value.green,
                blue: value.blue,
                alpha: value.alpha
            )
        }
        return [
            color("srgb-coral", NSColor(
                srgbRed: 0.92, green: 0.18, blue: 0.38, alpha: 1
            )),
            color("srgb-teal", NSColor(
                srgbRed: 0.10, green: 0.72, blue: 0.55, alpha: 1
            )),
            color("srgb-gray-500", NSColor(
                srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1
            )),
            color("p3-c7cd28", NSColor(
                displayP3Red: 199 / 255.0,
                green: 205 / 255.0,
                blue: 40 / 255.0,
                alpha: 1
            )),
            color("p3-pure-red", NSColor(
                displayP3Red: 1, green: 0, blue: 0, alpha: 1
            )),
            color("p3-vivid-green", NSColor(
                displayP3Red: 0.1, green: 0.95, blue: 0.2, alpha: 1
            )),
        ].compactMap { $0 } + Self.outOfDomainAlphaSweepColors
    }

    /// The alpha-only contract — alpha is coefficient 18 and touches nothing
    /// else — was certified from a fixed-RGB alpha sweep over **in-domain**
    /// colors. The product's commit path applies the same contract to
    /// wider-gamut colors: the resolution cache is keyed by RGB and the
    /// requested alpha is patched in, which is what makes dragging an opacity
    /// slider free. This sweep tests that assumption where it is being used,
    /// by resolving the same out-of-domain RGB at several alphas.
    private static var outOfDomainAlphaSweepColors: [GlassLabTintSweepColor] {
        let bases: [(String, NSColor)] = [
            ("p3-c7cd28", NSColor(
                displayP3Red: 199 / 255.0,
                green: 205 / 255.0,
                blue: 40 / 255.0,
                alpha: 1
            )),
            ("p3-pure-red", NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)),
        ]
        return bases.flatMap { name, base in
            [0.15, 0.4, 0.6, 0.8, 1.0].compactMap { alpha in
                guard let value = GlassMaterialColorValue(
                    base.withAlphaComponent(alpha)
                ) else { return nil }
                let id = "alpha-\(name)-a\(Int(alpha * 100))"
                return GlassLabTintSweepColor(
                    id: id,
                    label: id,
                    red: value.red,
                    green: value.green,
                    blue: value.blue,
                    alpha: value.alpha
                )
            }
        }
    }

    func performTintSyncResolutionCheck() async throws
        -> GlassLabTintSyncResolutionDocument {
        guard let hostWindow = state.testWindow.liveControlWindow else {
            throw GlassLabTintSweepError.noHostWindow
        }
        guard let probeHost = state.testWindow.liveControlProbeHost,
              probeHost.window === hostWindow else {
            throw GlassLabTintSweepError.probeHostUnavailable
        }
        let session = GlassLabTintSyncSession(
            hostWindow: hostWindow,
            mainProbeHost: probeHost
        )
        let rows = try await session.run(colors: Self.tintSyncResolutionColors)
        let timings = session.timings
        let current = GlassMaterialStyleAtlas.Environment.current(
            for: hostWindow.screen
        )
        return GlassLabTintSyncResolutionDocument(
            formatVersion: 1,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            operatingSystem: ProcessInfo.processInfo
                .operatingSystemVersionString,
            environment: .init(
                osMajorVersion: current.resolvedOSMajorVersion
                    ?? ProcessInfo.processInfo
                        .operatingSystemVersion.majorVersion,
                displaySignature: current.displaySignature,
                atlasSchemaVersion: GlassMaterialStyleAtlas
                    .currentSchemaVersion
            ),
            rows: rows,
            timings: timings,
            passed: rows.allSatisfy(\.passed)
        )
    }
}

@MainActor
private final class GlassLabTintSyncSession {
    private struct ProbePair {
        var mainOnCell: GlassMaterialStyleAtlas.Cell
        var mainOn: NSGlassEffectView
        var mainOff: NSGlassEffectView
    }

    private weak var hostWindow: NSWindow?
    private weak var mainProbeHost: NSView?
    private var mainContainer: NSView?
    private var witnessWindow: GlassLabTintSyncWitnessWindow?
    private var witnessContainer: NSView?

    init(hostWindow: NSWindow, mainProbeHost: NSView) {
        self.hostWindow = hostWindow
        self.mainProbeHost = mainProbeHost
    }

    func run(
        colors: [GlassLabTintSweepColor]
    ) async throws -> [GlassLabTintSyncResolutionRow] {
        guard let hostWindow, let mainProbeHost else {
            throw GlassLabTintSweepError.noHostWindow
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        hostWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        guard hostParticipates else {
            throw GlassLabTintSweepError.hostNotParticipating
        }

        let container = makeClippedContainer()
        mainProbeHost.addSubview(container)
        mainContainer = container
        guard prepareWitnessWindow(), let witnessContainer else {
            tearDown()
            throw GlassLabTintSweepError.witnessUnavailable
        }
        let pairs = makeProbePairs(
            mainContainer: container,
            witnessContainer: witnessContainer
        )
        defer {
            pairs.forEach {
                $0.mainOn.removeFromSuperview()
                $0.mainOff.removeFromSuperview()
            }
            tearDown()
        }

        mainProbeHost.layoutSubtreeIfNeeded()
        witnessWindow?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        guard hostParticipates, witnessIsMainOff else {
            throw GlassLabTintSweepError.witnessParticipated
        }

        var rows: [GlassLabTintSyncResolutionRow] = []
        for color in colors {
            try Task.checkCancellation()
            guard hostParticipates else {
                throw GlassLabTintSweepError.hostNotParticipating
            }
            guard witnessIsMainOff else {
                throw GlassLabTintSweepError.witnessParticipated
            }
            rows += try await measure(color: color, pairs: pairs)
        }
        return rows
    }

    private(set) var timings: [GlassLabTintSyncTiming] = []

    private func measure(
        color: GlassLabTintSweepColor,
        pairs: [ProbePair]
    ) async throws -> [GlassLabTintSyncResolutionRow] {
        guard let mainProbeHost else { return [] }
        let inDomain = [color.red, color.green, color.blue]
            .allSatisfy { $0 >= 0 && $0 <= 1 }

        let tStart = DispatchTime.now().uptimeNanoseconds
        // Clear first so a stale matrix from the previous color cannot be
        // mistaken for a synchronous resolution of this one.
        for pair in pairs {
            pair.mainOn.tintColor = nil
            pair.mainOff.tintColor = nil
        }
        mainProbeHost.layoutSubtreeIfNeeded()
        witnessWindow?.contentView?.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let tAfterClear = DispatchTime.now().uptimeNanoseconds

        for pair in pairs {
            pair.mainOn.tintColor = color.nsColor
            pair.mainOff.tintColor = color.nsColor
        }
        mainProbeHost.layoutSubtreeIfNeeded()
        witnessWindow?.contentView?.layoutSubtreeIfNeeded()
        // The whole claim under test: one commit, no sleeping.
        CATransaction.flush()
        let tAfterSet = DispatchTime.now().uptimeNanoseconds

        // Isolate the two readback costs the product resolver pays per color.
        var readbackMatrixCount = 0
        for pair in pairs {
            if GlassMaterialStyleAtlas.captureTintMatrix(from: pair.mainOn) != nil {
                readbackMatrixCount += 1
            }
            if GlassMaterialStyleAtlas.captureTintMatrix(from: pair.mainOff) != nil {
                readbackMatrixCount += 1
            }
        }
        let tAfterReadback = DispatchTime.now().uptimeNanoseconds
        for pair in pairs {
            _ = GlassMaterialStyleSample.capture(from: pair.mainOn)
            _ = GlassMaterialStyleSample.capture(from: pair.mainOff)
        }
        let tAfterProof = DispatchTime.now().uptimeNanoseconds
        let ms = { (a: UInt64, b: UInt64) in Double(b - a) / 1_000_000 }
        timings.append(GlassLabTintSyncTiming(
            colorID: color.id,
            clearFlushMilliseconds: ms(tStart, tAfterClear),
            setFlushMilliseconds: ms(tAfterClear, tAfterSet),
            matrixReadbackMilliseconds: ms(tAfterSet, tAfterReadback),
            pairedProofMilliseconds: ms(tAfterReadback, tAfterProof),
            totalMilliseconds: ms(tStart, tAfterProof)
        ))
        _ = readbackMatrixCount

        var flushMatrices: [GlassMaterialStyleAtlas.Cell: [Float]] = [:]
        var flushProof: [GlassMaterialStyleAtlas.Cell: Bool] = [:]
        for pair in pairs {
            let mainOffCell = Self.mainOffCell(for: pair.mainOnCell)
            if let matrix = GlassMaterialStyleAtlas.captureTintMatrix(
                from: pair.mainOn
            ) {
                flushMatrices[pair.mainOnCell] = matrix.matrix
            }
            if let matrix = GlassMaterialStyleAtlas.captureTintMatrix(
                from: pair.mainOff
            ) {
                flushMatrices[mainOffCell] = matrix.matrix
            }
            let proof: Bool
            if let onStyle = GlassMaterialStyleSample.capture(from: pair.mainOn),
               let offStyle = GlassMaterialStyleSample.capture(
                from: pair.mainOff
               ) {
                proof = GlassMaterialStyleAtlas.verifiesMainOn(
                    onStyle,
                    against: offStyle
                )
            } else {
                proof = false
            }
            flushProof[pair.mainOnCell] = proof
            flushProof[mainOffCell] = proof
        }

        // Now the accepted procedure, for the reference value.
        try await Task.sleep(for: .milliseconds(350))
        var settled: [GlassMaterialStyleAtlas.Cell: [Float]] = [:]
        var settledProof: [GlassMaterialStyleAtlas.Cell: Bool] = [:]
        var previous: [GlassMaterialStyleAtlas.Cell: [Float]] = [:]
        var stable: [GlassMaterialStyleAtlas.Cell: Int] = [:]
        for _ in 0..<24 where settled.count < pairs.count * 2 {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            guard hostParticipates else {
                throw GlassLabTintSweepError.hostNotParticipating
            }
            guard witnessIsMainOff else {
                throw GlassLabTintSweepError.witnessParticipated
            }
            for pair in pairs {
                let mainOffCell = Self.mainOffCell(for: pair.mainOnCell)
                guard let onStyle = GlassMaterialStyleSample.capture(
                    from: pair.mainOn
                ), let offStyle = GlassMaterialStyleSample.capture(
                    from: pair.mainOff
                ), let onMatrix = GlassMaterialStyleAtlas.captureTintMatrix(
                    from: pair.mainOn
                ), let offMatrix = GlassMaterialStyleAtlas.captureTintMatrix(
                    from: pair.mainOff
                ) else {
                    stable[pair.mainOnCell] = 0
                    continue
                }
                let proof = GlassMaterialStyleAtlas.verifiesMainOn(
                    onStyle,
                    against: offStyle
                )
                if previous[pair.mainOnCell] == onMatrix.matrix,
                   previous[mainOffCell] == offMatrix.matrix {
                    let count = (stable[pair.mainOnCell] ?? 0) + 1
                    stable[pair.mainOnCell] = count
                    if count >= 2 {
                        settled[pair.mainOnCell] = onMatrix.matrix
                        settled[mainOffCell] = offMatrix.matrix
                        settledProof[pair.mainOnCell] = proof
                        settledProof[mainOffCell] = proof
                    }
                } else {
                    previous[pair.mainOnCell] = onMatrix.matrix
                    previous[mainOffCell] = offMatrix.matrix
                    stable[pair.mainOnCell] = 0
                }
            }
        }

        var rows: [GlassLabTintSyncResolutionRow] = []
        for pair in pairs {
            for cell in [pair.mainOnCell, Self.mainOffCell(for: pair.mainOnCell)] {
                let flush = flushMatrices[cell]
                let reference = settled[cell]
                var difference: Double?
                if let flush, let reference, flush.count == reference.count {
                    difference = zip(flush, reference)
                        .map { abs(Double($0) - Double($1)) }
                        .max() ?? 0
                }
                var failure: String?
                if flush == nil {
                    failure = "no matrix present after CATransaction.flush()"
                } else if reference == nil {
                    failure = "the settled procedure never accepted a value"
                } else if let difference, difference > 0.0002 {
                    failure = "flush and settled values differ by \(difference)"
                } else if flushProof[cell] != true {
                    failure = "paired Main-On proof failed at flush"
                } else if settledProof[cell] != true {
                    failure = "paired Main-On proof failed when settled"
                }
                rows.append(GlassLabTintSyncResolutionRow(
                    colorID: color.id,
                    sourceColor: GlassMaterialColorValue(
                        red: color.red,
                        green: color.green,
                        blue: color.blue,
                        alpha: color.alpha
                    ),
                    isInCertifiedDomain: inDomain,
                    cell: GlassLabTintSweepCell(cell),
                    flushMatrix: flush,
                    settledMatrix: reference,
                    maximumDifference: difference,
                    pairedProofAtFlush: flushProof[cell] ?? false,
                    pairedProofWhenSettled: settledProof[cell] ?? false,
                    passed: failure == nil,
                    failure: failure
                ))
            }
        }
        return rows
    }

    private var hostParticipates: Bool {
        guard let hostWindow else { return false }
        return (hostWindow.isMainWindow || hostWindow.isKeyWindow)
            && NSApp.isActive
    }

    private var witnessIsMainOff: Bool {
        guard let window = witnessWindow else { return false }
        return window.isVisible
            && !window.isMainWindow
            && !window.isKeyWindow
            && NSApp.mainWindow !== window
            && NSApp.keyWindow !== window
    }

    private func prepareWitnessWindow() -> Bool {
        let frame = hostWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        let window = GlassLabTintSyncWitnessWindow(
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

    private func tearDown() {
        witnessWindow?.orderOut(nil)
        witnessWindow = nil
        witnessContainer = nil
        mainContainer?.removeFromSuperview()
        mainContainer = nil
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
