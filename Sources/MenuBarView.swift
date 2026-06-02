import SwiftUI

/// The dropdown shown when clicking the menu bar icon.
struct MenuBarView: View {
    @EnvironmentObject var manager: ServiceManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if manager.runners.isEmpty {
                emptyState
            } else {
                ForEach(manager.runners) { runner in
                    ServiceRow(runner: runner)
                    Divider().opacity(0.4)
                }
            }

            Divider()

            footer
        }
        .padding(8)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("StackBar")
                .font(.headline)
            Spacer()
            Button { manager.startAll() } label: {
                Label("Start all", systemImage: "play.fill")
            }
            .buttonStyle(.borderless)
            Button { manager.stopAll() } label: {
                Label("Stop all", systemImage: "stop.fill")
            }
            .buttonStyle(.borderless)
        }
        .padding(.bottom, 6)
        .labelStyle(.iconOnly)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No services yet")
                .foregroundStyle(.secondary)
            Button("Add a service…") { openSettings() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            Button { openSettings() } label: {
                Label("Edit services…", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(.top, 6)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }
}

/// One service line in the menu: dot, name, port, controls.
struct ServiceRow: View {
    @ObservedObject var runner: RunningService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: runner.status)

            VStack(alignment: .leading, spacing: 1) {
                Text(runner.config.name)
                    .font(.system(size: 13, weight: .medium))
                if let port = runner.config.port {
                    Text(":\(port)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button { runner.isLive ? runner.stop() : runner.start() } label: {
                Image(systemName: runner.isLive ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(runner.isLive ? "Stop" : "Start")

            Button { runner.restart() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Restart")

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "logs", value: runner.id)
            } label: {
                Image(systemName: "text.alignleft")
            }
            .buttonStyle(.borderless)
            .help("Logs")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
