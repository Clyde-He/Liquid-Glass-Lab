//
//  GlassMaterialAtlasProvider.swift
//  LiquidGlassLab
//
//  The product-shaped capture path: an invisible probe strip inside a real
//  host window (the app's own settings or main window) that fills a
//  GlassMaterialStyleAtlas opportunistically — Main-On cells while the
//  window is genuinely main, in parallel batches, persisted once per
//  environment. No floating probe window, no user-visible session: first
//  run costs a few seconds in the background, every later run loads from
//  disk and freezes immediately.
//

#if os(macOS)
import AppKit

@MainActor
public final class GlassMaterialAtlasProvider {
    /// Where a capture batch currently stands, for progress UI.
    public enum State: Equatable {
        case idle
        case waitingForMainWindow
        case capturing(completed: Int, total: Int)
        case ready
        case failed(String)
    }

    public private(set) var atlas: GlassMaterialStyleAtlas
    public private(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    /// Fires on every atlas change: a completed size batch, a tint capture,
    /// or the initial load from disk. Freeze (or re-freeze) from here.
    public var onAtlasUpdated: ((GlassMaterialStyleAtlas) -> Void)?
    public var onStateChanged: ((State) -> Void)?

    /// True when every Main-On cell carries the full probe-size coverage —
    /// the coverage `freeze(atlas:mainParticipation: true)` validates.
    public var isMainOnCoverageComplete: Bool {
        Self.mainOnCells.allSatisfy { cell in
            let sides = Set(atlas.sampleShortSides(for: cell))
            return shortSides.allSatisfy { sides.contains($0) }
        } && atlas.environment != nil
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

    private weak var hostWindow: NSWindow?
    private let shortSides: [Double]
    private let storageURL: URL?
    private let probeWidth: Double
    private var probeContainer: NSView?
    private var captureTask: Task<Void, Never>?
    private var tintCaptureTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Whether probes in the host window currently resolve Main-On. Checked
    /// before every accepted read, not just at batch start: participation can
    /// change mid-settle, and two stable Main-Off reads would otherwise pass
    /// the consecutive-equal settle into a Main-On cell.
    private var hostParticipates: Bool {
        guard let window = hostWindow else { return false }
        return (window.isMainWindow || window.isKeyWindow) && NSApp.isActive
    }

    /// - Parameters:
    ///   - hostWindow: a window that is genuinely main while the user works
    ///     in it — the app's own settings or main window. The probes live
    ///     clipped inside its content view and are never visible.
    ///   - shortSides: probe sizes bracketing the consumer's HUD range plus
    ///     the resolver gates (the ≤64pt floor and the 64–160pt blur ramp).
    ///   - storageURL: where the atlas persists; nil disables persistence.
    public init(
        hostWindow: NSWindow,
        shortSides: [Double] = [48, 64, 96, 160, 240, 320],
        storageURL: URL? = nil
    ) {
        self.hostWindow = hostWindow
        self.shortSides = shortSides.sorted()
        self.storageURL = storageURL
        self.probeWidth = max(480, (shortSides.max() ?? 320) * 1.5)
        self.atlas = GlassMaterialStyleAtlas()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Loads a compatible persisted atlas if one exists, and otherwise (or
    /// for whatever coverage is missing) captures at the next moment the
    /// host window is main and the app active. Idempotent.
    public func ensureCaptured() {
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode(
            GlassMaterialStyleAtlas.self,
            from: data
           ),
           saved.environment?.isCompatible(
            with: .current(for: hostWindow?.screen)
           ) == true {
            atlas = saved
            onAtlasUpdated?(atlas)
        }
        guard !isMainOnCoverageComplete else {
            state = .ready
            return
        }
        observeHostWindow()
        captureWhenPossible()
    }

    /// Captures the Main-On tint matrix for this color in all four cells,
    /// in one parallel batch — the capture-on-pick moment. Completion fires
    /// with false when the window is not main (retry on the next pick or
    /// call again from a main-window moment).
    public func captureTintMatrices(
        for color: NSColor,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard hostParticipates else {
            completion(false)
            return
        }
        // Latest pick wins: a superseded batch would only capture a hue the
        // HUD no longer shows, and letting it run would let two quick picks
        // interleave their merges.
        tintCaptureTask?.cancel()
        tintCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let needed = Self.mainOnCells.filter {
                self.atlas.tintMatrix(for: $0, matching: color) == nil
            }
            guard !needed.isEmpty else {
                completion(true)
                return
            }
            let referenceSide = min(200, self.shortSides.max() ?? 200)
            var probes: [(GlassMaterialStyleAtlas.Cell, NSGlassEffectView)] = []
            for cell in needed {
                let probe = self.makeProbe(
                    cell: cell,
                    shortSide: referenceSide
                )
                probe.tintColor = color
                probes.append((cell, probe))
            }
            defer { probes.forEach { $0.1.removeFromSuperview() } }

            // Collect locally and merge into the *current* atlas on
            // completion. A snapshot-and-replace would discard whatever a
            // concurrently running base-cell batch added during this settle
            // window — and the base capture computes its missing set once,
            // so a discarded cell would never be revisited.
            var collected: [(GlassMaterialStyleAtlas.Cell,
                             GlassMaterialStyleAtlas.TintMatrix)] = []
            for _ in 0..<20 where collected.count < probes.count {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, self.hostParticipates else {
                    completion(false)
                    return
                }
                collected = []
                for (cell, probe) in probes {
                    if let matrix = GlassMaterialStyleAtlas.captureTintMatrix(
                        from: probe
                    ), matrix.matrix.count == 20 {
                        collected.append((cell, matrix))
                    }
                }
            }
            let allCaptured = collected.count == probes.count
                && self.hostParticipates
            if allCaptured {
                for (cell, matrix) in collected {
                    self.atlas.addTintMatrix(matrix, for: cell)
                }
                self.persist()
                self.onAtlasUpdated?(self.atlas)
            }
            completion(allCaptured)
        }
    }

    // MARK: - Capture scheduling

    private func observeHostWindow() {
        guard observers.isEmpty, let window = hostWindow else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeMainNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        for name in names {
            observers.append(center.addObserver(
                forName: name,
                object: name == NSWindow.didBecomeMainNotification
                    ? window : nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.captureWhenPossible()
                }
            })
        }
    }

    private func captureWhenPossible() {
        guard captureTask == nil, !isMainOnCoverageComplete else { return }
        guard let window = hostWindow,
              window.isMainWindow || window.isKeyWindow,
              NSApp.isActive else {
            state = .waitingForMainWindow
            return
        }
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.captureTask = nil }
            await self.runCaptureBatches()
        }
    }

    /// One batch per cell: all of the cell's missing sizes settle in
    /// parallel, so wall clock is one materialize settle per cell rather
    /// than per sample.
    private func runCaptureBatches() async {
        let missing = Self.mainOnCells.map { cell in
            (cell, shortSides.filter {
                !atlas.sampleShortSides(for: cell).contains($0)
            })
        }.filter { !$0.1.isEmpty }
        let total = missing.reduce(0) { $0 + $1.1.count }
        var completed = 0
        state = .capturing(completed: 0, total: total)

        for (cell, sizes) in missing {
            guard hostParticipates else {
                state = .waitingForMainWindow
                return
            }
            var probes: [(Double, NSGlassEffectView)] = []
            for shortSide in sizes {
                probes.append((shortSide, makeProbe(
                    cell: cell,
                    shortSide: shortSide
                )))
            }
            defer { probes.forEach { $0.1.removeFromSuperview() } }

            var captured: [Double: GlassMaterialStyleSample] = [:]
            var previous: [Double: GlassMaterialStyleSample] = [:]
            for _ in 0..<24 {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
                // Participation lost mid-settle: discard the whole batch —
                // nothing accepted so far is provably Main-On anymore — and
                // let the main/active notifications restart it.
                guard hostParticipates else {
                    state = .waitingForMainWindow
                    return
                }
                for (shortSide, probe) in probes
                where captured[shortSide] == nil {
                    guard let sample = GlassMaterialStyleSample.capture(
                        from: probe
                    ) else {
                        previous[shortSide] = nil
                        continue
                    }
                    if previous[shortSide] == sample {
                        captured[shortSide] = sample
                    } else {
                        previous[shortSide] = sample
                    }
                }
                if captured.count == probes.count { break }
            }
            // Belt to the per-iteration check: never commit a batch into a
            // Main-On cell unless the host still participates right now.
            guard hostParticipates else {
                state = .waitingForMainWindow
                return
            }
            guard captured.count == probes.count else {
                state = .failed(
                    "Cell \(cell.isLightAppearance ? "Light" : "Dark")·"
                        + "\(cell.isClear ? "Clear" : "Regular") never settled."
                )
                return
            }
            for (shortSide, sample) in captured {
                atlas.add(sample, for: cell)
                _ = shortSide
            }
            completed += sizes.count
            state = .capturing(completed: completed, total: total)
            onAtlasUpdated?(atlas)
        }

        atlas.environment = .current(for: hostWindow?.screen)
        persist()
        state = .ready
        onAtlasUpdated?(atlas)
    }

    // MARK: - Probes

    /// A pristine glass born directly into the requested context: per-view
    /// appearance override, variant written before the first resolution
    /// completes, real size. It sits in a zero-sized clipping container in
    /// the host window's content view — participation is window-level, so
    /// the probe resolves Main-On authentically while showing nothing.
    private func makeProbe(
        cell: GlassMaterialStyleAtlas.Cell,
        shortSide: Double
    ) -> NSGlassEffectView {
        let container = ensureProbeContainer()
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

    private func ensureProbeContainer() -> NSView {
        if let probeContainer, probeContainer.superview != nil {
            return probeContainer
        }
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        hostWindow?.contentView?.addSubview(container)
        probeContainer = container
        return container
    }

    private func persist() {
        guard let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(atlas).write(to: storageURL, options: .atomic)
    }
}
#endif
