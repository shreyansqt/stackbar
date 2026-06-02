import SwiftUI
import AppKit

@main
struct StackBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The entire UI — the menu bar item AND the settings/logs windows — is
        // managed natively by MenuBarController (NSStatusItem + NSMenu + NSWindow)
        // in the AppDelegate. We expose no SwiftUI scenes; a menu-bar-only app
        // has no main window, and SwiftUI window scenes mount lazily, which made
        // the menu's open requests unreliable. WindowManager hosts the SwiftUI
        // views in plain NSWindows instead.
        Settings { EmptyView() }
    }
}

/// Owns the model + the native menu controller for the app's lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = ServiceManager()
    private var menuController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = MenuBarController(manager: manager)
    }
}

extension ServiceStatus {
    /// SF Symbol shown in the menu bar, color-coded via the symbol itself.
    var menuBarSymbol: String {
        switch self {
        case .idle: return "circle.dashed"
        case .starting, .stopping: return "circle.dotted"
        case .running: return "checkmark.circle.fill"
        case .crashed: return "exclamationmark.triangle.fill"
        }
    }
}
