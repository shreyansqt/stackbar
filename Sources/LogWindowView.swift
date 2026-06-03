import SwiftUI

/// Live log tail for a single service, styled as a console pane.
struct LogWindowView: View {
    @EnvironmentObject var manager: ServiceManager
    let serviceID: UUID?
    var kind: LogTarget.Kind = .combined
    var commandIndex: Int? = nil

    private var runner: RunningService? {
        guard let serviceID else { return nil }
        return manager.runners.first { $0.id == serviceID }
    }

    var body: some View {
        if let runner {
            LogContent(runner: runner, kind: kind, commandIndex: commandIndex)
        } else {
            ContentUnavailableView("Service not found", systemImage: "questionmark.folder")
                .frame(width: 420, height: 240)
        }
    }
}

private struct LogContent: View {
    @ObservedObject var runner: RunningService
    let kind: LogTarget.Kind
    let commandIndex: Int?
    @State private var autoScroll = true
    @State private var filter = ""

    /// Status to show: the specific start command's, or the service's.
    private var displayStatus: ServiceStatus {
        if kind == .start, let i = commandIndex, i < runner.commandStates.count { return runner.commandStates[i] }
        return runner.status
    }

    /// Subtitle: the specific command, or all commands.
    private var displayCommand: String {
        switch kind {
        case .start:
            if let i = commandIndex, i < runner.config.commands.count { return runner.config.commandStrings[i] }
        case .stop:
            if let i = commandIndex, i < runner.config.stopCommands.count { return "stop: \(runner.config.stopCommandStrings[i])" }
        case .combined:
            break
        }
        return runner.config.displayCommand
    }

    var body: some View {
        NavigationStack {
            console
                .frame(minWidth: 600, minHeight: 380)
                .toolbar { toolbarContent }
                .navigationTitle(runner.config.name)
                .navigationSubtitle(displayStatus.label)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                StatusDot(status: displayStatus)
                Text(displayCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .help("Auto-scroll")

            Button { runner.restart() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Restart")

            Button { runner.isLive ? runner.stop() : runner.start() } label: {
                Image(systemName: runner.isLive ? "stop.fill" : "play.fill")
            }
            .help(runner.isLive ? "Stop" : "Start")
        }
    }

    // MARK: - Console

    private var console: some View {
        LogTextView(lines: visibleLines, autoScroll: autoScroll)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .center) {
                if visibleLines.isEmpty {
                    Text(filter.isEmpty ? "No output yet" : "No lines match “\(filter)”")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .searchable(text: $filter, placement: .toolbar, prompt: "Filter log")
    }

    /// The source buffer: combined, a start command's, or a stop command's lines.
    private var sourceLines: [String] {
        switch kind {
        case .start:
            if let i = commandIndex, i < runner.logLinesByCommand.count { return runner.logLinesByCommand[i] }
        case .stop:
            if let i = commandIndex, i < runner.stopLogLinesByCommand.count { return runner.stopLogLinesByCommand[i] }
        case .combined:
            break
        }
        return runner.logLines
    }

    /// Lines after applying the toolbar filter.
    private var visibleLines: [String] {
        guard !filter.isEmpty else { return sourceLines }
        return sourceLines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }
}
