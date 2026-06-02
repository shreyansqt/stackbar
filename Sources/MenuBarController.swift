import AppKit
import SwiftUI
import Combine

/// Owns the native menu bar status item and its NSMenu. Rebuilds the menu from
/// ServiceManager state whenever statuses change, so it's a real AppKit menu
/// (native items, submenus, hover-to-open, ⌘ shortcuts) rather than a SwiftUI
/// popover.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let manager: ServiceManager
    private let windows: WindowManager
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    init(manager: ServiceManager) {
        self.manager = manager
        self.windows = WindowManager(manager: manager)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self            // rebuild items just before each open
        statusItem.menu = menu

        updateIcon()

        // Refresh the glyph (and the menu, if open) when any status changes.
        manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                // objectWillChange fires *before* the change applies; hop a tick.
                DispatchQueue.main.async { self?.updateIcon() }
            }
            .store(in: &cancellables)

        // Redraw the glyph when the system switches light/dark so it stays
        // legible (white on dark bar, black on light bar).
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    // MARK: - Status bar icon
    //
    // Status is conveyed by the glyph itself (all template images, so macOS colors
    // them correctly for any menu bar — no fragile colored-dot compositing):
    //   idle       → dim stack glyph
    //   allRunning → solid stack glyph
    //   booting    → rotating spinner (animated by a timer)
    //   crashed    → exclamation triangle

    private var spinnerTimer: Timer?
    private var spinnerAngle: CGFloat = 0

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let state = manager.iconState

        // Start/stop the spinner animation as we enter/leave the booting state.
        if state == .booting {
            startSpinner()
            return   // the spinner timer drives the image
        }
        stopSpinner()

        let image: NSImage?
        switch state {
        case .crashed:
            image = symbol("exclamationmark.triangle.fill")
        case .allRunning:
            image = symbol("square.stack.3d.up.fill")
        case .idle:
            image = symbol("square.stack.3d.up.fill", alpha: 0.4)
        case .booting:
            image = nil // handled above
        }
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
    }

    /// A template SF Symbol at the menu bar size, optionally drawn at reduced alpha
    /// (still a template, so macOS tints it to the bar color and our alpha dims it).
    private func symbol(_ name: String, alpha: CGFloat = 1) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "StackBar")?
            .withSymbolConfiguration(config) else { return nil }
        guard alpha < 1 else { return base }

        let image = NSImage(size: base.size)
        image.lockFocus()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: alpha)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: Spinner

    private func startSpinner() {
        guard spinnerTimer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickSpinner() }
        }
        RunLoop.main.add(timer, forMode: .common)
        spinnerTimer = timer
        tickSpinner()
    }

    private func stopSpinner() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        spinnerAngle = 0
    }

    private func tickSpinner() {
        guard let button = statusItem.button else { return }
        spinnerAngle -= .pi / 6   // 30° per tick, clockwise
        guard let base = symbol("arrow.triangle.2.circlepath") else { return }

        let size = base.size
        let image = NSImage(size: size)
        image.lockFocus()
        let ctx = NSGraphicsContext.current
        ctx?.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
        ctx?.cgContext.rotate(by: spinnerAngle)
        base.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2),
                  from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
    }

    // MARK: - NSMenuDelegate (build fresh each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Header row (disabled, just a title).
        let header = NSMenuItem(title: "StackBar", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if manager.runners.isEmpty {
            let empty = NSMenuItem(title: "No services yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            addItem(to: menu, title: "Add a service…", action: #selector(openSettings), key: "")
        } else {
            for runner in manager.runners {
                menu.addItem(serviceItem(for: runner))
            }
        }

        menu.addItem(.separator())

        addItem(to: menu, title: "Start All", action: #selector(startAll), key: "", symbol: "play.fill")
        addItem(to: menu, title: "Stop All", action: #selector(stopAll), key: "", symbol: "stop.fill")
        menu.addItem(.separator())
        addItem(to: menu, title: "Edit Services…", action: #selector(openSettings), key: "", symbol: "gearshape")
        addItem(to: menu, title: "Quit StackBar", action: #selector(quit), key: "q", symbol: "power")
    }

    // MARK: - Per-service item + submenu

    private func serviceItem(for runner: RunningService) -> NSMenuItem {
        let item = NSMenuItem(title: runner.config.name, action: nil, keyEquivalent: "")
        item.attributedTitle = serviceTitle(name: runner.config.name, port: runner.config.port)
        item.image = statusImage(for: runner.status)

        let submenu = NSMenu()
        let live = runner.isLive

        let toggle = NSMenuItem(title: live ? "Stop" : "Start",
                                action: live ? #selector(stopService(_:)) : #selector(startService(_:)),
                                keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = runner.id
        submenu.addItem(toggle)

        let restart = NSMenuItem(title: "Restart", action: #selector(restartService(_:)), keyEquivalent: "")
        restart.target = self
        restart.representedObject = runner.id
        submenu.addItem(restart)

        submenu.addItem(.separator())

        // Open in browser — only meaningful for services that expose a port
        // (front-ends, dev servers). Enabled only when the service is live.
        if runner.config.port != nil {
            let open = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = runner.id
            open.isEnabled = runner.isLive
            submenu.addItem(open)
        }

        let logs = NSMenuItem(title: "View Logs", action: #selector(viewLogs(_:)), keyEquivalent: "")
        logs.target = self
        logs.representedObject = runner.id
        submenu.addItem(logs)

        item.submenu = submenu
        return item
    }

    /// Service name in the normal menu color, with the port appended in a dimmer
    /// secondary color so it reads as metadata rather than part of the name.
    private func serviceTitle(name: String, port: Int?) -> NSAttributedString {
        let menuFont = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: menuFont,
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if let port {
            title.append(NSAttributedString(
                string: "   \(port)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: menuFont.pointSize - 1, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            ))
        }
        return title
    }

    /// A small colored dot image reflecting status, drawn as a template-free swatch.
    private func statusImage(for status: ServiceStatus) -> NSImage {
        let color: NSColor
        switch status.dotColor {
        case .gray: color = .tertiaryLabelColor
        case .yellow: color = .systemYellow
        case .green: color = .systemGreen
        case .red: color = .systemRed
        }
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String, symbol: String? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            image?.isTemplate = true   // adopt the menu's label color
            item.image = image
        }
        menu.addItem(item)
    }

    // MARK: - Actions

    private func runner(from sender: NSMenuItem) -> RunningService? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return manager.runner(id: id)
    }

    @objc private func startService(_ sender: NSMenuItem) { runner(from: sender)?.start() }
    @objc private func stopService(_ sender: NSMenuItem) { runner(from: sender)?.stop() }
    @objc private func restartService(_ sender: NSMenuItem) { runner(from: sender)?.restart() }

    @objc private func viewLogs(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        windows.openLogs(for: id)
    }

    @objc private func openInBrowser(_ sender: NSMenuItem) {
        guard let runner = runner(from: sender),
              let port = runner.config.port,
              let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func startAll() { manager.startAll() }
    @objc private func stopAll() { manager.stopAll() }

    @objc private func openSettings() {
        windows.openSettings()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

