import AppKit
import AdjustableGlass
import OSLog

/// Measures what the logs so far could not: whether frames actually reach the
/// screen at display cadence while Tint is being dragged. A display link ticks
/// once per delivered frame, so a drop shows up as a gap here even when every
/// library-side step is fast. It is opt-in because leaving this diagnostic
/// running also wakes the frozen-state sentinel every frame and makes an idle
/// demo look like a high-energy product workload.
@MainActor
private final class FrameCadenceMonitor {
    private static let optInEnvironmentKey =
        "ADJUSTABLE_GLASS_FRAME_MONITOR"

    private let log = Logger(
        subsystem: "design.specos.glasshud",
        category: "frames"
    )
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var longestGapMilliseconds = 0.0
    private var gapsOverTwoFrames = 0

    func start(on view: NSView) {
        guard ProcessInfo.processInfo.environment[
            Self.optInEnvironmentKey
        ] == "1" else { return }
        let link = view.displayLink(
            target: self,
            selector: #selector(tick(_:))
        )
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let now = sender.timestamp
        defer { lastTick = now }
        if windowStart == 0 { windowStart = now }
        frames += 1
        if lastTick > 0 {
            let gap = (now - lastTick) * 1000
            longestGapMilliseconds = max(longestGapMilliseconds, gap)
            if gap > 33 { gapsOverTwoFrames += 1 }
        }
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }
        log.notice(
            "presented \(self.frames, privacy: .public) frames/s longestGap=\(self.longestGapMilliseconds, format: .fixed(precision: 1), privacy: .public)ms dropped(>2frames)=\(self.gapsOverTwoFrames, privacy: .public)"
        )
        frames = 0
        longestGapMilliseconds = 0
        gapsOverTwoFrames = 0
        windowStart = now
    }
}

@main
@MainActor
enum ConsumerDemoApp {
    private static let delegate = ConsumerDemoAppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        installMainMenu(on: app)
        app.run()
    }

    private static func installMainMenu(on app: NSApplication) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Glass HUD Consumer Demo",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Reopen Reference",
            action: #selector(ConsumerDemoAppDelegate.reopenReference(_:)),
            keyEquivalent: "r"
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        app.mainMenu = mainMenu
    }
}

@MainActor
private final class ConsumerDemoAppDelegate:
    NSObject,
    NSApplicationDelegate
{
    private let variantControl = NSSegmentedControl(
        labels: ["Regular", "Clear"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let emphasisControl = NSSegmentedControl(
        labels: ["Normal", "Muted"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let appearanceControl = NSSegmentedControl(
        labels: ["System", "Light", "Dark"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let visibilitySlider = NSSlider(
        value: 1,
        minValue: 0,
        maxValue: 1,
        target: nil,
        action: nil
    )
    private let visibilityValue = NSTextField(labelWithString: "1.00")
    private let widthSlider = NSSlider(
        value: 320,
        minValue: 160,
        maxValue: 640,
        target: nil,
        action: nil
    )
    private let widthValue = NSTextField(labelWithString: "320")
    private let heightSlider = NSSlider(
        value: 120,
        minValue: 64,
        maxValue: 320,
        target: nil,
        action: nil
    )
    private let heightValue = NSTextField(labelWithString: "120")
    private let cornerRadiusSlider = NSSlider(
        value: 24,
        minValue: 0,
        maxValue: 60,
        target: nil,
        action: nil
    )
    private let cornerRadiusValue = NSTextField(labelWithString: "24")
    private let tintToggle = NSButton(
        checkboxWithTitle: "Use Tint",
        target: nil,
        action: nil
    )
    private let tintWell = NSColorWell()
    private let outerShadowToggle = NSButton(
        checkboxWithTitle: "Outer Shadow",
        target: nil,
        action: nil
    )
    private let panelLevelControl = NSSegmentedControl(
        labels: ["Normal", "Floating"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let placementControl = NSSegmentedControl(
        labels: ["Beside", "Menu Bar"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let panelShadowToggle = NSButton(
        checkboxWithTitle: "Panel Shadow",
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(
        wrappingLabelWithString: "Starting…"
    )
    private let hudDetailLabel = NSTextField(labelWithString: "")

    private var controlWindow: NSWindow?
    private var hudPanel: ConsumerHUDPanel?
    private weak var glassView: AdjustableGlassEffectView?
    private let frameMonitor = FrameCadenceMonitor()
    private var hudContentSize = CGSize(width: 320, height: 120)
    private var hudCornerRadius: CGFloat = 24
    private var isLayingOutHUDPanel = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controlWindow = buildControlWindow()
        let (hudPanel, glassView) = buildHUDPanel(relativeTo: controlWindow)
        self.controlWindow = controlWindow
        self.hudPanel = hudPanel
        self.glassView = glassView

        glassView.onStatusChange = { [weak self] status in
            self?.render(status: status)
        }
        glassView.onRequiredWindowInsetChange = { [weak self] _ in
            guard let self else { return }
            guard !self.isLayingOutHUDPanel else { return }
            self.layoutHUDPanel()
            self.updateHUDDetail()
        }

        layoutHUDPanel()
        hudPanel.orderFront(nil)
        if let hudContent = hudPanel.contentView {
            frameMonitor.start(on: hudContent)
        }
        controlWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
        applyConfiguration()
        render(status: glassView.status)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        // The control window is also the replaceable reference host. Keep the
        // app and nonactivating HUD alive after it closes so the lifecycle
        // scenario can detach the host and later restore it through
        // Window > Reopen Reference.
        false
    }

    private func buildControlWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glass HUD Consumer Demo"
        window.isReleasedWhenClosed = false
        window.center()

        let title = NSTextField(
            wrappingLabelWithString:
                "This target exercises only AdjustableGlass's supported API."
        )
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        variantControl.selectedSegment = 0
        emphasisControl.selectedSegment = 0
        appearanceControl.selectedSegment = 0
        for slider in [
            visibilitySlider,
            widthSlider,
            heightSlider,
            cornerRadiusSlider,
        ] {
            slider.isContinuous = true
        }
        outerShadowToggle.state = .off
        panelLevelControl.selectedSegment = 1
        placementControl.selectedSegment = 0
        tintWell.color = NSColor(
            srgbRed: 0.173,
            green: 0.617,
            blue: 0.842,
            alpha: 0.88
        )
        tintWell.isEnabled = false
        statusLabel.font = .monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        )
        statusLabel.textColor = .secondaryLabelColor

        for control in [
            variantControl,
            emphasisControl,
            appearanceControl,
            visibilitySlider,
            widthSlider,
            heightSlider,
            cornerRadiusSlider,
            tintToggle,
            tintWell,
            outerShadowToggle,
            panelLevelControl,
            placementControl,
            panelShadowToggle,
        ] {
            control.target = self
            control.action = #selector(controlChanged(_:))
        }

        let visibilityRow = NSStackView(views: [
            visibilitySlider,
            visibilityValue,
        ])
        visibilityRow.orientation = .horizontal
        visibilityRow.spacing = 10
        visibilityValue.alignment = .right
        visibilityValue.widthAnchor.constraint(equalToConstant: 42).isActive = true

        let widthRow = sliderRow(widthSlider, value: widthValue)
        let heightRow = sliderRow(heightSlider, value: heightValue)
        let cornerRadiusRow = sliderRow(
            cornerRadiusSlider,
            value: cornerRadiusValue
        )

        let tintRow = NSStackView(views: [tintToggle, tintWell])
        tintRow.orientation = .horizontal
        tintRow.spacing = 12

        let windowRow = NSStackView(views: [
            panelLevelControl,
            placementControl,
        ])
        windowRow.orientation = .horizontal
        windowRow.spacing = 12

        let toggleHUD = NSButton(
            title: "Hide HUD",
            target: self,
            action: #selector(toggleHUDVisibility(_:))
        )
        let retry = NSButton(
            title: "Retry Readiness",
            target: self,
            action: #selector(retryReadiness(_:))
        )
        let reopenReference = NSButton(
            title: "Reopen Reference",
            target: self,
            action: #selector(reopenReference(_:))
        )
        let actions = NSStackView(views: [toggleHUD, retry, reopenReference])
        actions.orientation = .horizontal
        actions.spacing = 10

        let stack = NSStackView(views: [
            title,
            labeledRow("Variant", variantControl),
            labeledRow("Emphasis", emphasisControl),
            labeledRow("Appearance", appearanceControl),
            labeledRow("Visibility", visibilityRow),
            labeledRow("Tint", tintRow),
            labeledRow("Width", widthRow),
            labeledRow("Height", heightRow),
            labeledRow("Corner Radius", cornerRadiusRow),
            separator(),
            labeledRow("Glass", outerShadowToggle),
            labeledRow("Window", windowRow),
            labeledRow("Panel", panelShadowToggle),
            actions,
            separator(),
            statusLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            variantControl.widthAnchor.constraint(equalToConstant: 430),
            emphasisControl.widthAnchor.constraint(equalToConstant: 430),
            appearanceControl.widthAnchor.constraint(equalToConstant: 430),
            visibilityRow.widthAnchor.constraint(equalToConstant: 430),
            widthRow.widthAnchor.constraint(equalToConstant: 430),
            heightRow.widthAnchor.constraint(equalToConstant: 430),
            cornerRadiusRow.widthAnchor.constraint(equalToConstant: 430),
            windowRow.widthAnchor.constraint(equalToConstant: 430),
        ])
        return window
    }

    private func buildHUDPanel(
        relativeTo controlWindow: NSWindow
    ) -> (ConsumerHUDPanel, AdjustableGlassEffectView) {
        let contentSize = hudContentSize
        let padding: CGFloat = 1
        let panelSize = CGSize(
            width: contentSize.width + padding * 2,
            height: contentSize.height + padding * 2
        )
        let panel = ConsumerHUDPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = ConsumerHUDDragContainerView(
            frame: NSRect(origin: .zero, size: panelSize)
        )
        container.visualGlassFrame = glassFrame(
            contentSize: contentSize,
            inset: padding
        )
        container.cornerRadius = hudCornerRadius
        let glass = AdjustableGlassEffectView(
            referenceWindow: controlWindow,
            referenceView: controlWindow.contentView,
            frame: NSRect(
                x: padding,
                y: padding,
                width: contentSize.width,
                height: contentSize.height
            )
        )
        glass.cornerRadius = hudCornerRadius

        let hudContent = NSView(
            frame: NSRect(origin: .zero, size: contentSize)
        )
        hudContent.autoresizingMask = [.width, .height]
        let title = NSTextField(labelWithString: "Product HUD")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(
            x: 0,
            y: 64,
            width: contentSize.width,
            height: 22
        )
        title.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        hudDetailLabel.font = .monospacedSystemFont(
            ofSize: 11,
            weight: .regular
        )
        hudDetailLabel.textColor = .secondaryLabelColor
        hudDetailLabel.alignment = .center
        hudDetailLabel.frame = NSRect(
            x: 0,
            y: 36,
            width: contentSize.width,
            height: 18
        )
        hudDetailLabel.autoresizingMask = [
            .width,
            .minYMargin,
            .maxYMargin,
        ]

        hudContent.addSubview(title)
        hudContent.addSubview(hudDetailLabel)
        glass.contentView = hudContent
        container.addSubview(glass)
        panel.contentView = container

        let origin = NSPoint(
            x: controlWindow.frame.maxX + 16,
            y: controlWindow.frame.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
        return (panel, glass)
    }

    private func layoutHUDPanel() {
        guard !isLayingOutHUDPanel,
              let panel = hudPanel,
              let glass = glassView
        else { return }
        isLayingOutHUDPanel = true
        defer { isLayingOutHUDPanel = false }

        let contentSize = hudContentSize
        let previousVisualOrigin = NSPoint(
            x: panel.frame.minX + glass.frame.minX,
            y: panel.frame.minY + glass.frame.minY
        )
        glass.setFrameSize(contentSize)
        glass.needsLayout = true
        glass.layoutSubtreeIfNeeded()
        let inset = glass.requiredWindowInset
        let total = CGSize(
            width: contentSize.width + inset * 2,
            height: contentSize.height + inset * 2
        )
        panel.setContentSize(total)
        glass.frame = glassFrame(contentSize: contentSize, inset: inset)
        if let container = panel.contentView as? ConsumerHUDDragContainerView {
            container.visualGlassFrame = glass.frame
        }
        panel.setFrameOrigin(NSPoint(
            x: previousVisualOrigin.x - inset,
            y: previousVisualOrigin.y - inset
        ))
    }

    private func glassFrame(
        contentSize: CGSize,
        inset: CGFloat
    ) -> NSRect {
        NSRect(
            x: inset,
            y: inset,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    private func positionHUDPanel() {
        guard let panel = hudPanel,
              let glass = glassView,
              let controlWindow,
              let screen = controlWindow.screen ?? NSScreen.main
        else { return }
        let contentSize = hudContentSize
        let inset = glass.requiredWindowInset
        let candidateOrigin: NSPoint
        if placementControl.selectedSegment == 1 {
            candidateOrigin = NSPoint(
                x: screen.visibleFrame.midX - contentSize.width / 2,
                y: screen.visibleFrame.maxY - contentSize.height - 12
            )
        } else {
            let rightX = controlWindow.frame.maxX + 16
            let leftX = controlWindow.frame.minX - contentSize.width - 16
            let fitsOnRight = rightX + contentSize.width
                <= screen.visibleFrame.maxX
            let x = fitsOnRight ? rightX : leftX
            candidateOrigin = NSPoint(
                x: x,
                y: controlWindow.frame.midY - contentSize.height / 2
            )
        }
        let visualOrigin = clampedVisualOrigin(
            candidateOrigin,
            contentSize: contentSize,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrameOrigin(NSPoint(
            x: visualOrigin.x - inset,
            y: visualOrigin.y - inset
        ))
    }

    private func clampedVisualOrigin(
        _ origin: NSPoint,
        contentSize: CGSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let maximumX = max(
            visibleFrame.minX,
            visibleFrame.maxX - contentSize.width
        )
        let maximumY = max(
            visibleFrame.minY,
            visibleFrame.maxY - contentSize.height
        )
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maximumX),
            y: min(max(origin.y, visibleFrame.minY), maximumY)
        )
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func sliderRow(
        _ slider: NSSlider,
        value: NSTextField
    ) -> NSView {
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let row = NSStackView(views: [slider, value])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return line
    }

    @objc private func controlChanged(_ sender: Any?) {
        tintWell.isEnabled = tintToggle.state == .on
        applyConfiguration()
        if let control = sender as? NSControl,
           control === placementControl
            || control === widthSlider
            || control === heightSlider {
            positionHUDPanel()
        }
    }

    @objc private func toggleHUDVisibility(_ sender: NSButton) {
        guard let hudPanel else { return }
        if hudPanel.isVisible {
            hudPanel.orderOut(nil)
            sender.title = "Show HUD"
        } else {
            hudPanel.orderFront(nil)
            sender.title = "Hide HUD"
            glassView?.prepareIfNeeded()
        }
    }

    @objc private func retryReadiness(_ sender: Any?) {
        glassView?.prepareIfNeeded()
    }

    /// Covers closing and reopening the reference window while the HUD stays
    /// visible: the control window can be closed at any time (its willClose
    /// detaches the reference host), and this re-attaches it without touching
    /// the controller or the rendered material. Reachable from the Window menu
    /// so it still works after the control window itself has been closed.
    @objc func reopenReference(_ sender: Any?) {
        guard let controlWindow else { return }
        glassView?.setReferenceHost(
            window: controlWindow,
            view: controlWindow.contentView
        )
        controlWindow.makeKeyAndOrderFront(nil)
        applyConfiguration()
    }

    private func applyConfiguration() {
        guard let glassView else { return }
        updateGeometryConfiguration()
        let visibility = visibilitySlider.doubleValue
        visibilityValue.stringValue = String(format: "%.2f", visibility)
        hudPanel?.level = panelLevelControl.selectedSegment == 0
            ? .normal
            : .floating
        hudPanel?.hasShadow = panelShadowToggle.state == .on
        if let container = hudPanel?.contentView
            as? ConsumerHUDDragContainerView {
            container.cornerRadius = hudCornerRadius
        }

        glassView.performConfigurationUpdates {
            glassView.cornerRadius = hudCornerRadius
            glassView.style = variantControl.selectedSegment == 1
                ? .clear
                : .regular
            glassView.effectState = emphasisControl.selectedSegment == 1
                ? .inactive
                : .active
            glassView.appearance = {
                switch appearanceControl.selectedSegment {
                case 1:
                    NSAppearance(named: .aqua)
                case 2:
                    NSAppearance(named: .darkAqua)
                default:
                    nil
                }
            }()
            glassView.effectAmount = CGFloat(visibility)
            glassView.tintColor = tintToggle.state == .on
                ? tintWell.color
                : nil
            glassView.hasOuterShadow = outerShadowToggle.state == .on
        }

        layoutHUDPanel()
        updateHUDDetail()
        render(status: glassView.status)
    }

    private func updateHUDDetail() {
        guard let glassView else { return }
        let tint = tintToggle.state == .on ? "Tint" : "No Tint"
        let shadow = outerShadowToggle.state == .on
            ? "Outer Shadow"
            : "No Outer Shadow"
        hudDetailLabel.stringValue = [
            variantControl.selectedSegment == 1 ? "Clear" : "Regular",
            emphasisControl.selectedSegment == 1 ? "Muted" : "Normal",
            tint,
            shadow,
            String(
                format: "%.0f×%.0f R%.0f",
                hudContentSize.width,
                hudContentSize.height,
                hudCornerRadius
            ),
            String(format: "Inset %.0f", glassView.requiredWindowInset),
            String(format: "G %.2f", visibilitySlider.doubleValue),
        ].joined(separator: " · ")
    }

    private func updateGeometryConfiguration() {
        let width = CGFloat(widthSlider.doubleValue.rounded())
        let height = CGFloat(heightSlider.doubleValue.rounded())
        hudContentSize = CGSize(width: width, height: height)

        let maximumCornerRadius = min(width, height) / 2
        cornerRadiusSlider.maxValue = Double(maximumCornerRadius)
        let cornerRadius = min(
            CGFloat(cornerRadiusSlider.doubleValue.rounded()),
            maximumCornerRadius
        )
        hudCornerRadius = cornerRadius

        widthSlider.doubleValue = Double(width)
        heightSlider.doubleValue = Double(height)
        cornerRadiusSlider.doubleValue = Double(cornerRadius)
        widthValue.stringValue = String(format: "%.0f", width)
        heightValue.stringValue = String(format: "%.0f", height)
        cornerRadiusValue.stringValue = String(format: "%.0f", cornerRadius)
    }

    private func render(status: AdjustableGlassEffectView.Status) {
        let hudState = hudPanel.map {
            $0.isMainWindow || $0.isKeyWindow ? "yes" : "no"
        } ?? "not attached"
        let insetState = glassView.map {
            String(format: "Inset %.0fpt", $0.requiredWindowInset)
        } ?? "Inset unavailable"
        let prefix = "HUD main/key: \(hudState) · \(insetState) · "
        switch status {
        case .idle:
            statusLabel.stringValue = prefix + "Status: idle"
        case .waitingForReferenceWindow:
            statusLabel.stringValue =
                prefix + "Status: waiting for active reference window"
        case .preparing:
            statusLabel.stringValue =
                prefix + "Status: preparing"
        case .ready:
            statusLabel.stringValue = prefix + "Status: ready"
        case let .unavailable(reason):
            statusLabel.stringValue =
                prefix + "Status: unavailable · \(describe(reason))"
        }
    }

    private func describe(
        _ reason: AdjustableGlassEffectView.UnavailabilityReason
    ) -> String {
        switch reason {
        case let .calibrationFailed(message):
            message
        case .materialInstallationFailed:
            "frozen material install failed"
        case .tintResolutionFailed:
            "tint is not verified yet"
        }
    }
}

private final class ConsumerHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ConsumerHUDDragContainerView: NSView {
    var visualGlassFrame: NSRect = .zero
    var cornerRadius: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        let path = NSBezierPath(
            roundedRect: visualGlassFrame,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        return path.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
