import SwiftUI
import AppKit

/// Minimal ANSI SGR (Select Graphic Rendition) parser. Dev servers like wrangler,
/// vite and webpack emit color via `ESC[ ... m` sequences; this turns a raw line
/// into styled runs so we can render the same colors they'd show in a terminal.
///
/// ANSI colors map to *semantic* colors (systemRed, systemGreen, …) rather than
/// fixed RGB, so they stay legible in both light and dark mode.
enum ANSI {
    /// A run of text carrying a resolved color index (nil = default text color).
    struct Run: Identifiable {
        let id = UUID()
        var text: String
        var colorIndex: Int?   // 0..7 ANSI color, or nil for default
        var bold: Bool

        var color: Color? { ANSI.swiftUIColor(colorIndex) }
        var nsColor: NSColor? { ANSI.nsColor(colorIndex) }
    }

    /// Active SGR state while scanning a line.
    private struct Style {
        var colorIndex: Int?
        var bold = false
    }

    static func parse(_ line: String) -> [Run] {
        guard line.contains("\u{1B}[") else {
            return [Run(text: line, colorIndex: nil, bold: false)]
        }

        var runs: [Run] = []
        var style = Style()
        var current = ""
        let scalars = Array(line.unicodeScalars)
        var i = 0

        func flush() {
            guard !current.isEmpty else { return }
            runs.append(Run(text: current, colorIndex: style.colorIndex, bold: style.bold))
            current = ""
        }

        while i < scalars.count {
            // Escape sequence: ESC [ <params> m
            if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "[" {
                var j = i + 2
                var params = ""
                while j < scalars.count, scalars[j] != "m", isParamScalar(scalars[j]) {
                    params.unicodeScalars.append(scalars[j])
                    j += 1
                }
                if j < scalars.count, scalars[j] == "m" {
                    flush()
                    apply(params, to: &style)
                    i = j + 1
                    continue
                }
            }
            current.unicodeScalars.append(scalars[i])
            i += 1
        }
        flush()
        return runs.isEmpty ? [Run(text: "", colorIndex: nil, bold: false)] : runs
    }

    private static func isParamScalar(_ s: Unicode.Scalar) -> Bool {
        (s >= "0" && s <= "9") || s == ";"
    }

    /// Apply one SGR sequence (e.g. "1;31") to the running style.
    private static func apply(_ params: String, to style: inout Style) {
        let codes = params.split(separator: ";").compactMap { Int($0) }
        let list = codes.isEmpty ? [0] : codes
        for code in list {
            switch code {
            case 0: style = Style()                    // reset
            case 1: style.bold = true
            case 22: style.bold = false
            case 39: style.colorIndex = nil            // default fg
            case 30...37: style.colorIndex = code - 30
            case 90...97: style.colorIndex = code - 90 // bright → same semantic
            default: break                             // ignore bg, underline, 256/truecolor for now
            }
        }
    }

    /// Map the 8 ANSI color indices to semantic SwiftUI colors (adapt to light/dark).
    static func swiftUIColor(_ n: Int?) -> Color? {
        switch n {
        case 0: return .secondary   // "black" → secondary so it's visible on dark too
        case 1: return .red
        case 2: return .green
        case 3: return .yellow
        case 4: return .blue
        case 5: return .purple
        case 6: return .teal
        default: return nil         // "white"/7 and nil → default label color
        }
    }

    /// Same mapping as NSColor, for NSAttributedString rendering.
    static func nsColor(_ n: Int?) -> NSColor? {
        switch n {
        case 0: return .secondaryLabelColor
        case 1: return .systemRed
        case 2: return .systemGreen
        case 3: return .systemYellow
        case 4: return .systemBlue
        case 5: return .systemPurple
        case 6: return .systemTeal
        default: return nil
        }
    }
}
