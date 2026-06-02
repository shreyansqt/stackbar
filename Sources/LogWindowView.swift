import SwiftUI

/// Live log tail for a single service, styled as a console pane.
struct LogWindowView: View {
    @EnvironmentObject var manager: ServiceManager
    let serviceID: UUID?

    private var runner: RunningService? {
        guard let serviceID else { return nil }
        return manager.runners.first { $0.id == serviceID }
    }

    var body: some View {
        if let runner {
            LogContent(runner: runner)
        } else {
            ContentUnavailableView("Service not found", systemImage: "questionmark.folder")
                .frame(width: 420, height: 240)
        }
    }
}

private struct LogContent: View {
    @ObservedObject var runner: RunningService
    @State private var autoScroll = true
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            console
                .frame(minWidth: 600, minHeight: 380)
                .toolbar { toolbarContent }
                .navigationTitle(runner.config.name)
                .navigationSubtitle(runner.status.label)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                StatusDot(status: runner.status)
                Text(runner.config.displayCommand)
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

    /// Lines after applying the toolbar filter.
    private var visibleLines: [String] {
        guard !filter.isEmpty else { return runner.logLines }
        return runner.logLines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }
}
