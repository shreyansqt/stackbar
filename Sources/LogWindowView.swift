import SwiftUI

/// Live log tail for a single service.
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
                .navigationTitle("\(runner.config.name) — logs")
        } else {
            Text("Service not found")
                .foregroundStyle(.secondary)
                .frame(width: 400, height: 200)
        }
    }
}

private struct LogContent: View {
    @ObservedObject var runner: RunningService
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logScroll
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private var toolbar: some View {
        HStack {
            StatusDot(status: runner.status)
            Text(runner.config.displayCommand)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
            Button { runner.restart() } label: { Image(systemName: "arrow.clockwise") }
            Button { runner.isLive ? runner.stop() : runner.start() } label: {
                Image(systemName: runner.isLive ? "stop.fill" : "play.fill")
            }
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(runner.logLines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: runner.logLines.count) { _, count in
                guard autoScroll, count > 0 else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }
}
