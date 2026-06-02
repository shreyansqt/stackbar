import SwiftUI

@main
struct StackBarApp: App {
    @StateObject private var manager = ServiceManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(manager)
        } label: {
            Image(systemName: manager.overallStatus.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        // Settings / edit-services window. Opened via openWindow(id:).
        Window("Services", id: "settings") {
            SettingsView()
                .environmentObject(manager)
        }
        .windowResizability(.contentSize)

        // Per-service log window, addressed by service UUID string.
        WindowGroup("Logs", id: "logs", for: UUID.self) { $serviceID in
            LogWindowView(serviceID: serviceID)
                .environmentObject(manager)
        }
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
