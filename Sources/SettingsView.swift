import SwiftUI
import AppKit

/// Add/edit/delete services. Master list on the left, editor on the right.
struct SettingsView: View {
    @EnvironmentObject var manager: ServiceManager
    @State private var selection: UUID?
    @State private var draft = Draft()

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 180, maxWidth: 220)
            editor
                .frame(minWidth: 360)
        }
        .frame(minHeight: 320)
        .onChange(of: selection) { _, newValue in loadDraft(for: newValue) }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(manager.runners) { runner in
                    HStack {
                        StatusDot(status: runner.status)
                        Text(runner.config.name)
                    }
                    .tag(runner.id)
                }
            }
            HStack {
                Button { newService() } label: { Image(systemName: "plus") }
                Button { deleteSelected() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private var editor: some View {
        Form {
            TextField("Name", text: $draft.name)

            HStack {
                TextField("Directory", text: $draft.directory)
                Button("Choose…") { chooseDirectory() }
            }

            Section("Commands") {
                ForEach(draft.commands.indices, id: \.self) { i in
                    HStack {
                        TextField("Command \(draft.commands.count > 1 ? "\(i + 1)" : "")",
                                  text: $draft.commands[i],
                                  prompt: Text("e.g. yarn start"))
                            .font(.system(.body, design: .monospaced))
                        if draft.commands.count > 1 {
                            Button { draft.commands.remove(at: i) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button { draft.commands.append("") } label: {
                    Label("Add command", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            Section("Stop commands (optional)") {
                ForEach(draft.stopCommands.indices, id: \.self) { i in
                    HStack {
                        TextField("Stop command", text: $draft.stopCommands[i],
                                  prompt: Text("e.g. docker compose down"))
                            .font(.system(.body, design: .monospaced))
                        Button { draft.stopCommands.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button { draft.stopCommands.append("") } label: {
                    Label("Add stop command", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            TextField("Port (optional)", text: $draft.portText,
                      prompt: Text("e.g. 3000"))

            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
        .padding(16)
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
