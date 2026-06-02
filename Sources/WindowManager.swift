import AppKit
import SwiftUI

/// Hosts the app's SwiftUI views (settings, per-service logs) in plain NSWindows.
/// A menu-bar-only app has no SwiftUI window scene that's reliably alive, so we
/// open windows natively here. Reuses an existing window when reopened.
@MainActor
final class WindowManager {
    private let manager: ServiceManager
    private var settingsWindow: NSWindow?
    /// One log window per service id.
    private var logWindows: [UUID: NSWindow] = [:]

    init(manager: ServiceManager) {
        self.manager = manager
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let root = SettingsView().environmentObject(manager)
        let window = makeWindow(title: "Services", content: root,
                                size: NSSize(width: 620, height: 420))
        window.delegate = closeObserver
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func openLogs(for id: UUID) {
        guard manager.runner(id: id) != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let existing = logWindows[id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let root = LogWindowView(serviceID: id).environmentObject(manager)
        let name = manager.runner(id: id)?.config.name ?? "Logs"
        let window = makeWindow(title: "\(name) — logs", content: root,
                                size: NSSize(width: 720, height: 460))
        window.delegate = closeObserver
        logWindows[id] = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Helpers

    private func makeWindow<Content: View>(title: String, content: Content, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Forgets a window when it closes so the next open makes a fresh one.
    private lazy var closeObserver: WindowCloseObserver = {
        WindowCloseObserver { [weak self] window in
            guard let self else { return }
            if window === self.settingsWindow { self.settingsWindow = nil }
            self.logWindows = self.logWindows.filter { $0.value !== window }
        }
    }()
}

/// Bridges NSWindowDelegate close events to a closure.
private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    private let onClose: (NSWindow) -> Void
    init(onClose: @escaping (NSWindow) -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onClose(window)
    }
}
