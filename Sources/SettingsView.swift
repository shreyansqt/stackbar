import SwiftUI
import AppKit

/// Add/edit/delete services. Master list on the left, editor on the right.
struct SettingsView: View {
    @EnvironmentObject var manager: ServiceManager
    @State private var selection: UUID?
    @State private var draft = Draft()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            editor
        }
        .frame(minWidth: 640, minHeight: 440)
        .onChange(of: selection) { _, newValue in loadDraft(for: newValue) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Services") {
                ForEach(manager.runners) { runner in
                    HStack(spacing: 8) {
                        StatusDot(status: runner.status)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(runner.config.name)
                                .lineLimit(1)
                            if let port = runner.config.port {
                                Text("localhost:\(port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(runner.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 2) {
                Button { newService() } label: { Image(systemName: "plus") }
                    .help("Add service")
                Button { deleteSelected() } label: { Image(systemName: "minus") }
                    .help("Remove service")
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - Editor

    private var editor: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("e.g. smarta-banking"))
                LabeledContent("Directory") {
                    HStack {
                        Text(draft.directory.isEmpty ? "No folder chosen" : draft.directory)
                            .foregroundStyle(draft.directory.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { chooseDirectory() }
                    }
                }
                TextField("Port", text: $draft.portText, prompt: Text("optional, e.g. 3000"))
            }

            Section("Start commands") {
                ForEach(draft.commands.indices, id: \.self) { i in
                    commandRow(text: $draft.commands[i],
                               placeholder: "e.g. yarn dev",
                               canRemove: draft.commands.count > 1) {
                        draft.commands.remove(at: i)
                    }
                }
                addButton("Add command") { draft.commands.append("") }
            }

            Section {
                ForEach(draft.stopCommands.indices, id: \.self) { i in
                    commandRow(text: $draft.stopCommands[i],
                               placeholder: "e.g. docker compose down",
                               canRemove: true) {
                        draft.stopCommands.remove(at: i)
                    }
                }
                addButton("Add stop command") { draft.stopCommands.append("") }
            } header: {
                Text("Stop commands")
            } footer: {
                Text("Run on stop, after the start processes are terminated. Optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(selection == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
    }

    private func commandRow(text: Binding<String>, placeholder: String,
                            canRemove: Bool, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("", text: text, prompt: Text(placeholder))
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.plain)
            if canRemove {
                Button(role: .destructive) { remove() } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: - Actions

    private func newService() {
        selection = nil
        draft = Draft()
    }

    private func loadDraft(for id: UUID?) {
        guard let id, let runner = manager.runners.first(where: { $0.id == id }) else { return }
        draft = Draft(from: runner.config)
    }

    private func save() {
        let port = Int(draft.portText.trimmingCharacters(in: .whitespaces))
        let trim = { (xs: [String]) in xs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let commands = trim(draft.commands)
        let stopCommands = trim(draft.stopCommands)
        if let id = selection {
            manager.updateService(Service(id: id, name: draft.name,
                                          directory: draft.directory,
                                          commands: commands, stopCommands: stopCommands, port: port))
        } else {
            let service = Service(name: draft.name, directory: draft.directory,
                                  commands: commands, stopCommands: stopCommands, port: port)
            manager.addService(service)
            selection = service.id
        }
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        manager.deleteService(id: id)
        selection = nil
        draft = Draft()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.directory = url.path
        }
    }
}

/// Mutable editor state, decoupled from the immutable Service model.
private struct Draft {
    var name = ""
    var directory = ""
    var commands: [String] = [""]
    var stopCommands: [String] = []
    var portText = ""

    init() {}

    init(from service: Service) {
        name = service.name
        directory = service.directory
        commands = service.commands.isEmpty ? [""] : service.commands
        stopCommands = service.stopCommands
        portText = service.port.map(String.init) ?? ""
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !directory.trimmingCharacters(in: .whitespaces).isEmpty &&
        commands.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
