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
    private var lastState: ServiceManager.IconState?
    private var checkmarkTimer: Timer?

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let state = manager.iconState
        defer { lastState = state }

        // Start/stop the spinner animation as we enter/leave the booting state.
        if state == .booting {
            cancelCheckmark()
            startSpinner()
            return   // the spinner timer drives the image
        }
        stopSpinner()

        // When we *transition into* all-running, flash a checkmark briefly before
        // settling to the solid glyph — a small "everything's up" confirmation.
        if state == .allRunning, lastState != nil, lastState != .allRunning {
            setImage(symbol("checkmark.rectangle.stack.fill"), on: button)
            cancelCheckmark()
            let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let button = self.statusItem.button else { return }
                    if self.manager.iconState == .allRunning {
                        self.setImage(self.symbol("rectangle.stack.fill"), on: button)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            checkmarkTimer = timer
            return
        }

        // Don't clobber the checkmark while it's still showing (further updates can
        // fire during all-running). Let the checkmark timer settle the glyph.
        if state == .allRunning, checkmarkTimer != nil { return }

        let image: NSImage?
        switch state {
        case .crashed:
            image = symbol("exclamationmark.triangle.fill")
        case .allRunning, .idle:
            // Brightness reflects how many services are running: 40% (none) → 100%
            // (all). allRunning is just the 100% end of this same scale.
            let alpha = 0.4 + 0.6 * manager.runningFraction
            image = symbol("rectangle.stack.fill", alpha: alpha)
        case .booting:
            image = nil // handled above
        }
        setImage(image, on: button)
    }

    private func setImage(_ image: NSImage?, on button: NSStatusBarButton) {
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
    }

    private func cancelCheckmark() {
        checkmarkTimer?.invalidate()
        checkmarkTimer = nil
    }

    /// A template SF Symbol at the menu bar size, optionally drawn at reduced alpha
    /// and nudged vertically (points; negative = down) for optical alignment. Stays
    /// a template so macOS tints it to the bar color.
    private func symbol(_ name: String, alpha: CGFloat = 1, yOffset: CGFloat = 0) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "StackBar")?
            .withSymbolConfiguration(config) else { return nil }
        guard alpha < 1 || yOffset != 0 else { return base }

        // Pad the canvas by |yOffset| so the shift doesn't clip the glyph.
        let pad = abs(yOffset)
        let size = NSSize(width: base.size.width, height: base.size.height + pad)
        let image = NSImage(size: size)
        image.lockFocus()
        base.draw(at: NSPoint(x: 0, y: yOffset < 0 ? 0 : yOffset),
                  from: .zero, operation: .sourceOver, fraction: alpha)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: Spinner

    private func startSpinner() {
        guard spinnerTimer == nil else { return }
        // 60fps for a smooth spin.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
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
        spinnerAngle -= .pi / 60   // ~3° per tick at 60fps → one rotation ≈ 2s
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
            let empty = NSMenuItem(
                title: manager.workspaces.isEmpty
                    ? "No workspace yet — add a folder to scan"
                    : "No .stackbar.json files found in your workspace",
                action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            addItem(to: menu, title: "Manage Workspaces…", action: #selector(openSettings), key: "")
        } else {
            // One section per workspace: a header row (whose submenu carries that
            // workspace's Start All / Stop All), then its services.
            let groups = manager.runnersByWorkspace
            for (index, group) in groups.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                menu.addItem(workspaceHeader(for: group.workspace))
                for runner in group.runners {
                    menu.addItem(serviceItem(for: runner))
                }
            }
        }

        menu.addItem(.separator())

        addItem(to: menu, title: "Refresh Services", action: #selector(refresh), key: "", symbol: "arrow.clockwise")
        menu.addItem(.separator())
        addItem(to: menu, title: "Workspaces…", action: #selector(openSettings), key: "", symbol: "folder")
        addItem(to: menu, title: "Quit StackBar", action: #selector(quit), key: "q", symbol: "power")
    }

    @objc private func refresh() { manager.rescan() }

    // MARK: - Per-service item + submenu

    private func serviceItem(for runner: RunningService) -> NSMenuItem {
        let item = NSMenuItem(title: runner.config.name, action: nil, keyEquivalent: "")
        item.attributedTitle = serviceTitle(name: runner.config.name, port: runner.config.port)
        item.image = statusImage(for: runner.status)

        let submenu = NSMenu()
        let live = runner.isLive
        let busy = runner.isBusy

        // Toggle: Start / Stop, with busy ("Starting…"/"Stopping…") disabled.
        let toggle = NSMenuItem(title: busy ? (live ? "Stopping…" : "Starting…") : (live ? "Stop" : "Start"),
                                action: busy ? nil : (live ? #selector(stopService(_:)) : #selector(startService(_:))),
                                keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = runner.id
        toggle.isEnabled = !busy
        submenu.addItem(toggle)

        // STATUS section: one-line status (in full label color), plus Open in Browser.
        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Status"))
        let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusItem.attributedTitle = NSAttributedString(string: runner.statusLine, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,   // not the dim disabled grey
        ])
        statusItem.image = statusImage(for: runner.status)
        submenu.addItem(statusItem)
        if runner.config.port != nil {
            let open = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = runner.id
            open.isEnabled = runner.isLive
            submenu.addItem(open)
        }

        // START COMMANDS section: each command, enabled once it has logs.
        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Start commands"))
        for idx in runner.config.commands.indices {
            let hasLogs = runner.startCommandsRan.contains(idx) && !runner.logLinesByCommand[safe: idx, default: []].isEmpty
            let entry = commandItem(title: runner.config.commandStrings[idx], hasLogs: hasLogs,
                                    target: LogTarget(id: runner.id, kind: .start, commandIndex: idx))
            entry.image = statusImage(for: runner.commandStates[safe: idx, default: .idle])
            submenu.addItem(entry)
        }

        // STOP COMMANDS section — only when the service has stop commands.
        if !runner.config.stopCommands.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(sectionHeader("Stop commands"))
            for idx in runner.config.stopCommands.indices {
                let hasLogs = runner.stopCommandsRan.contains(idx) && !runner.stopLogLinesByCommand[safe: idx, default: []].isEmpty
                let entry = commandItem(title: runner.config.stopCommandStrings[idx], hasLogs: hasLogs,
                                        target: LogTarget(id: runner.id, kind: .stop, commandIndex: idx))
                submenu.addItem(entry)
            }
        }

        item.submenu = submenu
        return item
    }

    /// A workspace section header. The row is styled like `sectionHeader`, and its
    /// submenu carries Start All / Stop All scoped to that workspace. A nil
    /// workspace is the catch-all "Other" group (no scoped bulk controls).
    private func workspaceHeader(for workspace: URL?) -> NSMenuItem {
        let name = workspace?.lastPathComponent ?? "Other"
        let item = sectionHeader(name)

        guard let workspace else { return item }   // "Other" has no scoped controls

        item.isEnabled = true   // submenu parents must be enabled to open
        let submenu = NSMenu()
        let start = NSMenuItem(title: "Start All", action: #selector(startAllInWorkspace(_:)), keyEquivalent: "")
        start.target = self
        start.representedObject = workspace
        start.image = templateSymbol("play.fill")
        submenu.addItem(start)
        let stop = NSMenuItem(title: "Stop All", action: #selector(stopAllInWorkspace(_:)), keyEquivalent: "")
        stop.target = self
        stop.representedObject = workspace
        stop.image = templateSymbol("stop.fill")
        submenu.addItem(stop)
        item.submenu = submenu
        return item
    }

    private func templateSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: name)
        image?.isTemplate = true
        return image
    }

    /// A section header drawn in a stronger color than NSMenu's faint default.
    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,   // stronger than tertiary/disabled
        ])
        item.isEnabled = false
        return item
    }

    /// Max characters of a command shown in the menu before truncating (keeps the
    /// submenu from stretching arbitrarily wide). Full command shown on hover.
    private static let maxCommandChars = 40

    /// A command row: truncated label, enabled only when it has logs, full command
    /// as a tooltip.
    private func commandItem(title: String, hasLogs: Bool, target: LogTarget) -> NSMenuItem {
        let shown = title.count > Self.maxCommandChars
            ? String(title.prefix(Self.maxCommandChars - 1)) + "…"
            : title
        let item = NSMenuItem(title: shown,
                              action: hasLogs ? #selector(viewLogs(_:)) : nil, keyEquivalent: "")
        item.target = self
        item.representedObject = target
        item.isEnabled = hasLogs
        item.toolTip = title   // full command on hover
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
        guard let target = sender.representedObject as? LogTarget else { return }
        windows.openLogs(for: target.id, kind: target.kind, commandIndex: target.commandIndex)
    }

    @objc private func openInBrowser(_ sender: NSMenuItem) {
        guard let runner = runner(from: sender),
              let port = runner.config.port,
              let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func startAllInWorkspace(_ sender: NSMenuItem) {
        guard let ws = sender.representedObject as? URL else { return }
        manager.startAll(in: ws)
    }

    @objc private func stopAllInWorkspace(_ sender: NSMenuItem) {
        guard let ws = sender.representedObject as? URL else { return }
        manager.stopAll(in: ws)
    }

    @objc private func openSettings() {
        windows.openSettings()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private extension Array {
    /// Safe index access with a default for out-of-range — keeps menu building
    /// resilient if status/log arrays momentarily lag the command list.
    subscript(safe index: Int, default fallback: Element) -> Element {
        indices.contains(index) ? self[index] : fallback
    }
}

/// Identifies which log a menu item opens. Reference type so it rides on an
/// NSMenuItem's representedObject.
final class LogTarget: NSObject {
    enum Kind { case combined, start, stop }
    let id: UUID
    let kind: Kind
    let commandIndex: Int?
    init(id: UUID, kind: Kind, commandIndex: Int?) {
        self.id = id
        self.kind = kind
        self.commandIndex = commandIndex
    }
}

