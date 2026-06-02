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

    private var lines: [(offset: Int, line: String)] {
        let all = Array(runner.logLines.enumerated()).map { (offset: $0.offset, line: $0.element) }
        guard !filter.isEmpty else { return all }
        return all.filter { $0.line.localizedCaseInsensitiveContains(filter) }
    }

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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.offset) { item in
                        LogLine(number: item.offset + 1, text: item.line)
                            .id(item.offset)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .center) {
                if lines.isEmpty {
                    Text(filter.isEmpty ? "No output yet" : "No lines match “\(filter)”")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .onChange(of: runner.logLines.count) { _, count in
                guard autoScroll, count > 0 else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter log")
    }
}

/// One console line: a dim gutter line-number + the monospaced text.
private struct LogLine: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
                .textSelection(.disabled)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(lineColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0.5)
    }

    /// Tint obvious error/warn lines so they stand out in the console.
    private var lineColor: Color {
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("✘") || lower.contains("fatal") {
            return .red
        }
        if lower.contains("warn") {
            return .orange
        }
        if text.hasPrefix("[stackbar]") || text.hasPrefix("[stop]") {
            return .secondary
        }
        return .primary
    }
}
