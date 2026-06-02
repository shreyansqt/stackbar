import SwiftUI
import AppKit

/// Manage workspace folders. StackBar discovers services by scanning these for
/// `.stackbar.json` files — config lives in the repos, not in the app.
struct SettingsView: View {
    @EnvironmentObject var manager: ServiceManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if manager.workspaces.isEmpty {
                emptyState
            } else {
                content
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workspaces").font(.headline)
                Text("Folders StackBar scans for .stackbar.json files")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { manager.rescan() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No workspaces yet").font(.title3)
            Text("Add a folder (e.g. your projects directory). StackBar finds every\n.stackbar.json under it and lists those services.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Workspace…") { chooseWorkspace() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(manager.workspaces, id: \.self) { ws in
                    workspaceSection(ws)
                }
            }
            .padding(16)
        }
    }

    private func workspaceSection(_ ws: URL) -> some View {
        let services = manager.runners.filter { $0.config.directory.hasPrefix(ws.path) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(ws.path).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(role: .destructive) { manager.removeWorkspace(ws) } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.borderless)
            }
            if services.isEmpty {
                Text("No .stackbar.json files found here.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            } else {
                ForEach(services) { runner in
                    HStack(spacing: 8) {
                        StatusDot(status: runner.status)
                        Text(runner.config.name)
                        if let port = runner.config.port {
                            Text("localhost:\(port)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.leading, 22)
                }
            }
            Divider()
        }
    }

    private var footer: some View {
        HStack {
            Button { chooseWorkspace() } label: { Label("Add Workspace…", systemImage: "plus") }
            Spacer()
            Text("\(manager.runners.count) service\(manager.runners.count == 1 ? "" : "s") discovered")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Workspace"
        if panel.runModal() == .OK, let url = panel.url {
            manager.addWorkspace(url)
        }
    }
}
