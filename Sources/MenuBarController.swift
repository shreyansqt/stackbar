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
    }

    // MARK: - Status bar icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol = manager.overallStatus.menuBarSymbol
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "StackBar")
        button.image?.isTemplate = true
    }

    // MARK: - NSMenuDelegate (build fresh each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if manager.runners.isEmpty {
            let empty = NSMenuItem(title: "No services yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            addItem(to: menu, title: "Add a service…", action: #selector(openSettings), key: ",")
        } else {
            for runner in manager.runners {
                menu.addItem(serviceItem(for: runner))
            }
        }

        menu.addItem(.separator())

        addItem(to: menu, title: "Start All", action: #selector(startAll), key: "s")
        addItem(to: menu, title: "Stop All", action: #selector(stopAll), key: "x")
        menu.addItem(.separator())
        addItem(to: menu, title: "Edit Services…", action: #selector(openSettings), key: ",")
        addItem(to: menu, title: "Quit StackBar", action: #selector(quit), key: "q")
    }

    // MARK: - Per-service item + submenu

    private func serviceItem(for runner: RunningService) -> NSMenuItem {
        let port = runner.config.port.map { " :\($0)" } ?? ""
        let item = NSMenuItem(title: "\(runner.config.name)\(port)", action: nil, keyEquivalent: "")
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

    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
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
