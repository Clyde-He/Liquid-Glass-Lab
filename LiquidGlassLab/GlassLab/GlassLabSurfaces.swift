//
//  GlassLabSurfaces.swift
//  LiquidGlassLab
//
//  A single independent glass test surface that can be rebuilt as a transparent
//  Panel or a normal titled NSWindow. The final sampled states are always
//  non-key; real main-window participation selects between the flat and active
//  Recipe branches.
//

#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Shared glass content

/// Reports the end of every internal NSGlassEffectView layout pass. AppKit can
/// replace the private CAFilter/SDF subtree while resolving Variant or window
/// participation, so the host uses this as the authoritative point to stamp a
/// captured Override onto the newly installed objects before Core Animation
/// presents them.
private final class GlassLabManagedEffectView: NSGlassEffectView {
    var didFinishLayout: ((NSGlassEffectView) -> Void)?

    override func layout() {
        super.layout()
        didFinishLayout?(self)
    }
}

/// Window content shared by every host type. Normal windows show the original
/// colorful Canvas backdrop; the Panel stays transparent so it can inspect the
/// real desktop/content behind it. In every case the glass keeps its exact
/// requested size instead of being clamped by an in-window preview.
final class GlassLabGlassHost: NSView {
    private(set) var glass: NSGlassEffectView
    private let gradient = CAGradientLayer()
    private let label = NSTextField(wrappingLabelWithString: Array(
        repeating: "Liquid Glass Lab 0123456789 ●▲■◆ AppKit Glass",
        count: 16
    ).joined(separator: "  "))
    private var glassSize = NSSize(width: 480, height: 200)
    private var glassPadding: CGFloat = 40
    private weak var state: GlassLabState?
    private var isRestampingAfterLayout = false

    init(showsCanvasBackdrop: Bool) {
        glass = GlassLabManagedEffectView()
        super.init(frame: .zero)
        wantsLayer = true

        gradient.colors = [
            NSColor.systemBlue.cgColor,
            NSColor.systemPurple.cgColor,
            NSColor.systemOrange.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.isHidden = !showsCanvasBackdrop
        layer?.addSublayer(gradient)

        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.textColor = .white
        label.isHidden = !showsCanvasBackdrop
        addSubview(label)
        addSubview(glass)
        installLayoutRestamp(on: glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(with state: GlassLabState) {
        self.state = state
        let size = NSSize(width: state.glassWidth, height: state.glassHeight)
        let padding = CGFloat(state.windowPadding)
        if size != glassSize || padding != glassPadding {
            glassSize = size
            glassPadding = padding
            needsLayout = true
        }
        glass.cornerRadius = state.cornerRadius
        if !state.isCapturingRecipeMatrix {
            GlassLabTuning.applyRecipe(from: state, to: glass)
        }
    }

    /// Discards private filter mutations without changing the host window or
    /// its real key/main participation.
    func rebuildGlass(with state: GlassLabState) {
        let previous = glass
        let replacement = GlassLabManagedEffectView()
        glass = replacement
        installLayoutRestamp(on: replacement)
        previous.removeFromSuperview()
        addSubview(replacement)
        needsLayout = true
        layoutSubtreeIfNeeded()
        update(with: state)
        DispatchQueue.main.async { [weak self, weak state] in
            guard let self, let state else { return }
            self.layoutSubtreeIfNeeded()
            self.update(with: state)
        }
    }

    private func installLayoutRestamp(on glass: NSGlassEffectView) {
        guard let managedGlass = glass as? GlassLabManagedEffectView else { return }
        managedGlass.didFinishLayout = { [weak self] glass in
            self?.restampOverridesAfterLayout(on: glass)
        }
    }

    /// A Recipe setter can return before AppKit swaps in its resolved private
    /// layers. Stamping in `update(with:)` therefore protects the old tree but
    /// not necessarily the replacement. This callback makes the captured
    /// payload the final model-layer write for every newly laid-out tree.
    private func restampOverridesAfterLayout(on candidate: NSGlassEffectView) {
        guard candidate === glass,
              let state,
              !state.isCapturingRecipeMatrix,
              !isRestampingAfterLayout,
              state.shaderOverridesEnabled || state.highlightOverridesEnabled else { return }
        isRestampingAfterLayout = true
        defer { isRestampingAfterLayout = false }
        GlassLabTuning.applyOverrides(from: state, to: candidate)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        label.frame = bounds.insetBy(dx: 8, dy: 8)
        glass.frame = NSRect(
            x: glassPadding,
            y: glassPadding,
            width: glassSize.width,
            height: glassSize.height
        )
    }
}

/// SwiftUI semantic usages do not create an NSGlassEffectView. They synthesize
/// their own SDFLayer/CABackdropLayer/filter composition inside an
/// NSHostingView, so this host keeps that renderer isolated from the AppKit
/// Recipe surface while preserving the same window backdrop and geometry.
final class GlassLabSemanticHost: NSView {
    private let gradient = CAGradientLayer()
    private let label = NSTextField(wrappingLabelWithString: Array(
        repeating: "Liquid Glass Lab 0123456789 ●▲■◆ SwiftUI Glass",
        count: 16
    ).joined(separator: "  "))
    private let model = GlassLabSemanticModel()
    private let semanticView: NSHostingView<GlassLabSemanticSurfaceView>
    private var semanticSize = NSSize(width: 480, height: 200)
    private var semanticPadding: CGFloat = 40

    var inspectionRootLayer: CALayer? { semanticView.layer }
    var renderStatus: String { model.status }

    init(showsCanvasBackdrop: Bool) {
        semanticView = NSHostingView(
            rootView: GlassLabSemanticSurfaceView(model: model)
        )
        super.init(frame: .zero)
        wantsLayer = true

        gradient.colors = [
            NSColor.systemBlue.cgColor,
            NSColor.systemPurple.cgColor,
            NSColor.systemOrange.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.isHidden = !showsCanvasBackdrop
        layer?.addSublayer(gradient)

        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.textColor = .white
        label.isHidden = !showsCanvasBackdrop
        addSubview(label)

        semanticView.wantsLayer = true
        addSubview(semanticView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(with state: GlassLabState) {
        let size = NSSize(width: state.glassWidth, height: state.glassHeight)
        let padding = CGFloat(state.windowPadding)
        if size != semanticSize || padding != semanticPadding {
            semanticSize = size
            semanticPadding = padding
            needsLayout = true
        }
        model.update(
            usage: state.semanticUsage,
            cornerRadius: state.cornerRadius
        )
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        label.frame = bounds.insetBy(dx: 8, dy: 8)
        semanticView.frame = NSRect(
            x: semanticPadding,
            y: semanticPadding,
            width: semanticSize.width,
            height: semanticSize.height
        )
        semanticView.layoutSubtreeIfNeeded()
    }
}

// MARK: - Control-window anchor

/// Registers the SwiftUI Playground window as the key/main restoration target.
/// This replaces the old Canvas view's accidental role as the window anchor.
struct GlassLabControlWindowAnchor: NSViewRepresentable {
    let state: GlassLabState

    func makeNSView(context: Context) -> GlassLabWindowAnchorView {
        let view = GlassLabWindowAnchorView()
        view.windowDidChange = { window in
            state.testWindow.setControlWindow(window)
        }
        return view
    }

    func updateNSView(_ view: GlassLabWindowAnchorView, context: Context) {
        state.testWindow.setControlWindow(view.window)
    }

    static func dismantleNSView(_ view: GlassLabWindowAnchorView, coordinator: ()) {
        // Removing the representable calls viewDidMoveToWindow with nil. Drop
        // the callback first so a departing SwiftUI tree cannot touch the
        // controller after GlassLabView.onDisappear has torn its window down.
        view.windowDidChange = nil
    }
}

final class GlassLabWindowAnchorView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}

// MARK: - Managed AppKit windows

private protocol GlassLabManagedWindow: AnyObject {
    var allowsKeyWindow: Bool { get set }
    var allowsMainWindow: Bool { get set }
    var participationDidChange: (() -> Void)? { get set }
}

private final class GlassLabManagedPanel: NSPanel, GlassLabManagedWindow {
    var allowsKeyWindow = false
    var allowsMainWindow = false
    var participationDidChange: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { allowsMainWindow }

    override func becomeKey() {
        super.becomeKey()
        participationDidChange?()
    }

    override func resignKey() {
        super.resignKey()
        participationDidChange?()
    }

    override func becomeMain() {
        super.becomeMain()
        participationDidChange?()
    }

    override func resignMain() {
        super.resignMain()
        participationDidChange?()
    }
}

private final class GlassLabManagedStandardWindow: NSWindow, GlassLabManagedWindow {
    var allowsKeyWindow = false
    var allowsMainWindow = false
    var participationDidChange: (() -> Void)?

    override var canBecomeKey: Bool { allowsKeyWindow }
    override var canBecomeMain: Bool { allowsMainWindow }

    override func becomeKey() {
        super.becomeKey()
        participationDidChange?()
    }

    override func resignKey() {
        super.resignKey()
        participationDidChange?()
    }

    override func becomeMain() {
        super.becomeMain()
        participationDidChange?()
    }

    override func resignMain() {
        super.resignMain()
        participationDidChange?()
    }
}

// MARK: - Single test-window controller

@MainActor
final class GlassLabTestWindowController {
    private var window: NSWindow?
    private weak var glassHost: GlassLabGlassHost?
    private weak var semanticHost: GlassLabSemanticHost?
    private weak var state: GlassLabState?
    private weak var controlWindow: NSWindow?
    private weak var previousKeyWindow: NSWindow?
    private weak var previousMainWindow: NSWindow?
    private var currentHostType: GlassLabWindowHostType?
    private var currentRendererMode: GlassLabRendererMode?
    private var isActive = false
    private var isApplyingParticipation = false
    private var mainReconciliationTask: Task<Void, Never>?
    private var contextSettleTask: Task<Void, Never>?

    var liveGlass: NSGlassEffectView? { glassHost?.glass }
    var liveSemanticLayerRoot: CALayer? { semanticHost?.inspectionRootLayer }
    var semanticRenderStatus: String? { semanticHost?.renderStatus }
    var liveWindow: NSWindow? { window }

    var isActuallyKey: Bool { window.map { NSApp.keyWindow === $0 } ?? false }
    var isActuallyMain: Bool { window.map { NSApp.mainWindow === $0 } ?? false }

    func setControlWindow(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        controlWindow = window
        if previousKeyWindow == nil { previousKeyWindow = window }
        if previousMainWindow == nil { previousMainWindow = window }
        if isActive, self.window == nil, let state, state.isTestWindowVisible {
            sync(with: state)
        }
    }

    /// GlassLabView.onAppear is the sole owner of the test-window lifetime.
    /// Window-anchor and observation callbacks may arrive before appearance or
    /// after disappearance, but they must never create a second orphan window.
    func activate(with state: GlassLabState) {
        isActive = true
        self.state = state
        // During NavigationSplitView's initial layout, onAppear can precede
        // the anchor's viewDidMoveToWindow. Wait for a real restoration target
        // instead of briefly ordering a context-less Panel.
        guard controlWindow != nil else { return }
        sync(with: state)
    }

    func sync(with state: GlassLabState) {
        guard isActive else { return }
        self.state = state
        rememberCurrentControlWindows()

        guard state.isTestWindowVisible else {
            if state.isTestWindowMain {
                state.isTestWindowMain = false
            }
            discardWindow()
            return
        }

        let didRecreateWindow = window == nil
            || currentHostType != state.windowHostType
            || currentRendererMode != state.rendererMode
        if didRecreateWindow {
            recreateWindow(for: state)
        }
        guard let window, let host = surfaceHost else { return }
        resize(window, host: host, for: state)
        // sync also runs for continuous context streams (the geometry
        // sliders). Replaying the ordering dance while participation already
        // matches would re-front the window and schedule context
        // re-resolutions on every tick.
        if didRecreateWindow
            || !participationSatisfiesRequest(state.isTestWindowMain, for: window) {
            applyMainWindowState(state.isTestWindowMain, to: window)
        }
        scheduleMainWindowReconciliation(for: state)
    }

    func rebuildGlass(with state: GlassLabState) {
        glassHost?.rebuildGlass(with: state)
    }

    /// AppKit clears main-window participation while the application is
    /// inactive. Reapply the requested state only after activation has
    /// completed; attempting `makeMain()` during deactivation is ignored.
    func applicationDidBecomeActive(with state: GlassLabState) {
        self.state = state
        scheduleMainWindowReconciliation(for: state)
        refreshResolvedContextAfterSettling()
    }

    /// Actual main participation cannot survive process deactivation, but an
    /// Override is a captured Recipe payload rather than a promise to remain
    /// NSApp.mainWindow. Resolve the truthful inactive context, then transplant
    /// the captured payload back onto it so the rendered material can stay
    /// frozen while the requested Main state is remembered for reactivation.
    func applicationDidResignActive(with state: GlassLabState) {
        self.state = state
        refreshResolvedContextAfterSettling()
    }

    func tearDown() {
        isActive = false
        mainReconciliationTask?.cancel()
        contextSettleTask?.cancel()
        discardWindow()
        state = nil
    }

    private func recreateWindow(for state: GlassLabState) {
        let previousOrigin = window?.frame.origin
        discardWindow()

        let contentRect = initialContentRect(for: state)
        let newWindow: NSWindow
        switch state.windowHostType {
        case .panel:
            let panel = GlassLabManagedPanel(
                contentRect: contentRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.isMovableByWindowBackground = true
            newWindow = panel
        case .window:
            let standardWindow = GlassLabManagedStandardWindow(
                contentRect: contentRect,
                styleMask: [.titled, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            standardWindow.title = "Glass Lab Test Window"
            standardWindow.isOpaque = true
            standardWindow.hasShadow = true
            standardWindow.level = .normal
            newWindow = standardWindow
        }

        newWindow.isReleasedWhenClosed = false
        let showsCanvasBackdrop = state.windowHostType != .panel
        let host: NSView
        switch state.rendererMode {
        case .recipe:
            let recipeHost = GlassLabGlassHost(
                showsCanvasBackdrop: showsCanvasBackdrop
            )
            glassHost = recipeHost
            semanticHost = nil
            host = recipeHost
        case .semanticUsage:
            let usageHost = GlassLabSemanticHost(
                showsCanvasBackdrop: showsCanvasBackdrop
            )
            semanticHost = usageHost
            glassHost = nil
            host = usageHost
        }
        newWindow.contentView = host
        if let previousOrigin {
            newWindow.setFrameOrigin(previousOrigin)
        }
        if let managedWindow = newWindow as? GlassLabManagedWindow {
            managedWindow.participationDidChange = { [weak self] in
                self?.reflectActualParticipation()
            }
        }
        window = newWindow
        currentHostType = state.windowHostType
        currentRendererMode = state.rendererMode
        resize(newWindow, host: host, for: state)
    }

    private func discardWindow() {
        guard let window else { return }
        mainReconciliationTask?.cancel()
        contextSettleTask?.cancel()
        restoreControlWindow(after: window)
        (window as? GlassLabManagedWindow)?.participationDidChange = nil
        window.orderOut(nil)
        self.window = nil
        glassHost = nil
        semanticHost = nil
        currentHostType = nil
        currentRendererMode = nil
    }

    private func applyMainWindowState(_ wantsMain: Bool, to window: NSWindow) {
        guard let managedWindow = window as? GlassLabManagedWindow else { return }
        isApplyingParticipation = true
        defer { isApplyingParticipation = false }

        if wantsMain {
            rememberCurrentControlWindows()
            // A titled NSWindow cannot reliably enter main-only directly. The
            // controlled probe first made it genuinely key/main, transferred
            // key back to a second window, then called makeMain() again. Replay
            // that transition for Window; panels can become main directly
            // while permanently refusing key status.
            managedWindow.allowsKeyWindow = currentHostType == .window
            managedWindow.allowsMainWindow = true
            window.orderFrontRegardless()

            if NSApp.isActive {
                let keyTarget = preferredKeyWindow(excluding: window)
                if currentHostType == .window, NSApp.mainWindow !== window {
                    window.makeKeyAndOrderFront(nil)
                    window.makeMain()
                }
                if NSApp.keyWindow === window {
                    keyTarget?.makeKeyAndOrderFront(nil)
                }
                if NSApp.mainWindow !== window {
                    window.makeMain()
                }
            }
        } else {
            managedWindow.allowsKeyWindow = false
            managedWindow.allowsMainWindow = false
            // Ordering a non-activating panel can still transiently make it
            // AppKit's main window during launch. Put it on screen first, then
            // restore the control window so Off ends in a truthful neither
            // state instead of immediately undoing that restoration.
            window.orderFrontRegardless()
            restoreControlWindow(after: window)
        }

        refreshResolvedContextAfterSettling()
    }

    /// The requested Main state is satisfied only when both the allowed and
    /// the actual participation match; allows-flags alone can linger from a
    /// recreate while AppKit has already moved main elsewhere.
    private func participationSatisfiesRequest(
        _ wantsMain: Bool,
        for window: NSWindow
    ) -> Bool {
        guard let managedWindow = window as? GlassLabManagedWindow else { return true }
        return managedWindow.allowsMainWindow == wantsMain
            && managedWindow.allowsKeyWindow == (wantsMain && currentHostType == .window)
            && isActuallyMain == wantsMain
            && !isActuallyKey
    }

    /// A Toggle click finishes by making the control window key/main after its
    /// SwiftUI state callback has already run. Reassert the requested main-only
    /// state after that AppKit event settles; keep one cancellable task so
    /// rapid user changes cannot replay an obsolete request.
    private func scheduleMainWindowReconciliation(for state: GlassLabState) {
        mainReconciliationTask?.cancel()
        mainReconciliationTask = Task { @MainActor [weak self, weak state] in
            for delay in [60, 180] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, let state,
                      state.isTestWindowVisible,
                      self.currentHostType == state.windowHostType,
                      let window = self.window else { return }
                let matchesRequest = self.isActuallyMain == state.isTestWindowMain
                    && !self.isActuallyKey
                if matchesRequest { return }
                guard NSApp.isActive else { return }
                self.applyMainWindowState(state.isTestWindowMain, to: window)
            }
        }
    }

    private func restoreControlWindow(after testWindow: NSWindow) {
        if NSApp.keyWindow === testWindow,
           let target = preferredKeyWindow(excluding: testWindow) {
            target.makeKeyAndOrderFront(nil)
        }
        if NSApp.mainWindow === testWindow,
           let target = preferredMainWindow(excluding: testWindow) {
            target.makeMain()
        }
    }

    private func preferredKeyWindow(excluding testWindow: NSWindow) -> NSWindow? {
        [controlWindow, previousKeyWindow, previousMainWindow]
            .compactMap { $0 }
            .first { $0 !== testWindow && $0.canBecomeKey }
    }

    private func preferredMainWindow(excluding testWindow: NSWindow) -> NSWindow? {
        [controlWindow, previousMainWindow, previousKeyWindow]
            .compactMap { $0 }
            .first { $0 !== testWindow && $0.canBecomeMain }
    }

    private func rememberCurrentControlWindows() {
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            previousKeyWindow = keyWindow
            controlWindow = controlWindow ?? keyWindow
        }
        if let mainWindow = NSApp.mainWindow, mainWindow !== window {
            previousMainWindow = mainWindow
            controlWindow = controlWindow ?? mainWindow
        }
    }

    private func reflectActualParticipation() {
        guard !isApplyingParticipation, let state else { return }
        // The toggle is desired state, not a mirror of AppKit's transient
        // callbacks. Reconcile just participation instead of resyncing the
        // entire surface for every become/resign callback.
        scheduleMainWindowReconciliation(for: state)
        refreshResolvedContextAfterSettling()
    }

    /// One coalescing owner for the deferred passes: rapid context events
    /// (activation, participation callbacks, reconciliation) reset the settle
    /// window instead of queueing a backlog of re-resolutions, each of which
    /// forces a layout and a full Override restamp.
    private func refreshResolvedContextAfterSettling() {
        guard let glass = glassHost?.glass else { return }
        refreshResolvedContextAndRestamp(on: glass)
        contextSettleTask?.cancel()
        contextSettleTask = Task { @MainActor [weak self, weak glass] in
            for delay in [0, 120] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, let glass else { return }
                self.refreshResolvedContextAndRestamp(on: glass)
            }
        }
    }

    /// Keep context resolution and Override mutation in one ordered pipeline.
    /// The previous implementation scheduled these from separate owners at
    /// overlapping 120 ms deadlines, allowing either the Flat resolver or the
    /// captured payload to become the final write nondeterministically.
    private func refreshResolvedContextAndRestamp(on glass: NSGlassEffectView) {
        guard glass === glassHost?.glass else { return }
        GlassLabTuning.refreshResolvedWindowContext(on: glass)
        guard glass === glassHost?.glass, let state else { return }
        GlassLabTuning.applyOverrides(from: state, to: glass)
    }

    private func resize(
        _ window: NSWindow,
        host: NSView,
        for state: GlassLabState
    ) {
        let padding = CGFloat(state.windowPadding)
        let size = NSSize(
            width: state.glassWidth + padding * 2,
            height: state.glassHeight + padding * 2
        )
        if window.contentLayoutRect.size != size {
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(size)
            window.setFrameTopLeftPoint(topLeft)
        }
        host.frame = NSRect(origin: .zero, size: size)
        glassHost?.update(with: state)
        semanticHost?.update(with: state)
        host.layoutSubtreeIfNeeded()
    }

    private var surfaceHost: NSView? {
        if let glassHost { return glassHost }
        return semanticHost
    }

    private func initialContentRect(for state: GlassLabState) -> NSRect {
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let padding = state.windowPadding
        return NSRect(
            x: screen.midX - state.glassWidth / 2 - padding + 40,
            y: screen.midY - state.glassHeight / 2 - padding - 40,
            width: state.glassWidth + padding * 2,
            height: state.glassHeight + padding * 2
        )
    }
}
#endif
