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
    private let tintToggle = NSButton(
        checkboxWithTitle: "Use Tint",
        target: nil,
        action: nil
    )
    private let tintWell = NSColorWell()
    private let statusLabel = NSTextField(
        wrappingLabelWithString: "Starting…"
    )
    private let hudDetailLabel = NSTextField(labelWithString: "")

    private var controlWindow: NSWindow?
    private var hudPanel: ConsumerHUDPanel?
    private weak var glassView: AdjustableGlassEffectView?
    private let frameMonitor = FrameCadenceMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controlWindow = buildControlWindow()
        let (hudPanel, glassView) = buildHUDPanel(relativeTo: controlWindow)
        self.controlWindow = controlWindow
        self.hudPanel = hudPanel
        self.glassView = glassView

        glassView.onStatusChange = { [weak self] status in
            self?.render(status: status)
        }

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
        true
    }

    private func buildControlWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glass HUD Consumer Demo"
        window.isReleasedWhenClosed = false
        window.center()

        let title = NSTextField(
            wrappingLabelWithString:
                "This target imports only AdjustableGlass. "
                + "It has no Capture or Atlas controls."
        )
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        variantControl.selectedSegment = 0
        emphasisControl.selectedSegment = 0
        appearanceControl.selectedSegment = 0
        visibilitySlider.isContinuous = true
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
            tintToggle,
            tintWell,
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

        let tintRow = NSStackView(views: [tintToggle, tintWell])
        tintRow.orientation = .horizontal
        tintRow.spacing = 12

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
        let actions = NSStackView(views: [toggleHUD, retry])
        actions.orientation = .horizontal
        actions.spacing = 10

        let stack = NSStackView(views: [
            title,
            labeledRow("Variant", variantControl),
            labeledRow("Emphasis", emphasisControl),
            labeledRow("Appearance", appearanceControl),
            labeledRow("Visibility", visibilityRow),
            labeledRow("Tint", tintRow),
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
            variantControl.widthAnchor.constraint(equalToConstant: 280),
            emphasisControl.widthAnchor.constraint(equalToConstant: 280),
            appearanceControl.widthAnchor.constraint(equalToConstant: 280),
            visibilityRow.widthAnchor.constraint(equalToConstant: 280),
        ])
        return window
    }

    private func buildHUDPanel(
        relativeTo controlWindow: NSWindow
    ) -> (ConsumerHUDPanel, AdjustableGlassEffectView) {
        let contentSize = CGSize(width: 320, height: 120)
        let padding: CGFloat = 64
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

        let container = NSView(
            frame: NSRect(origin: .zero, size: panelSize)
        )
        let glass = AdjustableGlassEffectView(
            referenceWindow: controlWindow,
            frame: NSRect(
                x: padding,
                y: padding,
                width: contentSize.width,
                height: contentSize.height
            )
        )
        glass.cornerRadius = 24

        let title = NSTextField(labelWithString: "Product HUD")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(
            x: padding,
            y: padding + 64,
            width: contentSize.width,
            height: 22
        )
        hudDetailLabel.font = .monospacedSystemFont(
            ofSize: 11,
            weight: .regular
        )
        hudDetailLabel.textColor = .secondaryLabelColor
        hudDetailLabel.alignment = .center
        hudDetailLabel.frame = NSRect(
            x: padding,
            y: padding + 36,
            width: contentSize.width,
            height: 18
        )

        container.addSubview(glass)
        container.addSubview(title)
        container.addSubview(hudDetailLabel)
        panel.contentView = container

        let origin = NSPoint(
            x: controlWindow.frame.maxX + 16,
            y: controlWindow.frame.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
        return (panel, glass)
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

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return line
    }

    @objc private func controlChanged(_ sender: Any?) {
        tintWell.isEnabled = tintToggle.state == .on
        applyConfiguration()
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

    private func applyConfiguration() {
        guard let glassView else { return }
        let visibility = visibilitySlider.doubleValue
        visibilityValue.stringValue = String(format: "%.2f", visibility)

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
        glassView.tintColor = tintToggle.state == .on ? tintWell.color : nil

        let tint = tintToggle.state == .on ? "Tint" : "No Tint"
        hudDetailLabel.stringValue = [
            variantControl.selectedSegment == 1 ? "Clear" : "Regular",
            emphasisControl.selectedSegment == 1 ? "Muted" : "Normal",
            tint,
            String(format: "G %.2f", visibility),
        ].joined(separator: " · ")
    }

    private func render(status: AdjustableGlassEffectView.Status) {
        let hudState = hudPanel.map {
            $0.isMainWindow || $0.isKeyWindow ? "yes" : "no"
        } ?? "not attached"
        let prefix = "HUD main/key: \(hudState) · "
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
