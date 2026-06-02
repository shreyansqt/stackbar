import SwiftUI
import AppKit

/// Renders log lines in a real NSTextView (the engine Terminal/Xcode use) for
/// crisp monospaced layout, native selection + ⌘F find, and smooth scrolling on
/// large logs. ANSI color runs become NSAttributedString color attributes.
struct LogTextView: NSViewRepresentable {
    let lines: [String]
    let autoScroll: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor      // adapts light/dark
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.usesFindBar = true                           // ⌘F
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.allowsUndo = false

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(Self.attributedLog(lines))

        if autoScroll {
            textView.scrollToEndOfDocument(nil)
        }
    }

    // MARK: - Build the attributed log

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    private static let gutterFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    private static func attributedLog(_ lines: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let gutterWidth = max(3, String(lines.count).count)

        for (idx, line) in lines.enumerated() {
            // Dim right-aligned line number gutter.
            let num = String(format: "%\(gutterWidth)d  ", idx + 1)
            out.append(NSAttributedString(string: num, attributes: [
                .font: gutterFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            out.append(attributedLine(line))
            out.append(NSAttributedString(string: "\n"))
        }
        return out
    }

    private static func attributedLine(_ line: String) -> NSAttributedString {
        if line.contains("\u{1B}[") {
            let result = NSMutableAttributedString()
            for run in ANSI.parse(line) {
                result.append(NSAttributedString(string: run.text, attributes: [
                    .font: run.bold ? boldFont : font,
                    .foregroundColor: run.nsColor ?? NSColor.labelColor,
                ]))
            }
            return result
        }
        // No ANSI: keyword heuristic so plain output still gets sensible tinting.
        return NSAttributedString(string: line.isEmpty ? " " : line, attributes: [
            .font: font,
            .foregroundColor: heuristicColor(line),
        ])
    }

    private static func heuristicColor(_ text: String) -> NSColor {
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("✘") || lower.contains("fatal")
            || lower.contains("eaddrinuse") || lower.contains("exception") {
            return .systemRed
        }
        if lower.contains("warn") || lower.contains("deprecat") {
            return .systemOrange
        }
        if lower.contains("ready") || lower.contains("compiled successfully")
            || lower.contains("found 0 errors") || lower.contains("listening") {
            return .systemGreen
        }
        if text.hasPrefix("[stackbar]") || text.hasPrefix("[stop]") {
            return .secondaryLabelColor
        }
        return .labelColor
    }
}
