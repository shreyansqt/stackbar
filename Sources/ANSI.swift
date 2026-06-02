import SwiftUI

/// Minimal ANSI SGR (Select Graphic Rendition) parser. Dev servers like wrangler,
/// vite and webpack emit color via `ESC[ ... m` sequences; this turns a raw line
/// into styled runs so we can render the same colors they'd show in a terminal.
///
/// ANSI colors map to *semantic* SwiftUI colors (.red, .green, …) rather than
/// fixed RGB, so they stay legible in both light and dark mode.
enum ANSI {
    struct Run: Identifiable {
        let id = UUID()
        var text: String
        var color: Color?
        var bold: Bool
    }

    /// Active SGR state while scanning a line.
    private struct Style {
        var color: Color?
        var bold = false
    }

    static func parse(_ line: String) -> [Run] {
        guard line.contains("\u{1B}[") else {
            return [Run(text: line, color: nil, bold: false)]
        }

        var runs: [Run] = []
        var style = Style()
        var current = ""
        let scalars = Array(line.unicodeScalars)
        var i = 0

        func flush() {
            guard !current.isEmpty else { return }
            runs.append(Run(text: current, color: style.color, bold: style.bold))
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
        return runs.isEmpty ? [Run(text: "", color: nil, bold: false)] : runs
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
            case 39: style.color = nil                 // default fg
            case 30...37: style.color = standardColor(code - 30)
            case 90...97: style.color = standardColor(code - 90) // bright → same semantic
            default: break                             // ignore bg, underline, 256/truecolor for now
            }
        }
    }

    /// Map the 8 ANSI colors to semantic SwiftUI colors (adapt to light/dark).
    private static func standardColor(_ n: Int) -> Color? {
        switch n {
        case 0: return .secondary   // "black" — use secondary so it's visible on dark too
        case 1: return .red
        case 2: return .green
        case 3: return .yellow
        case 4: return .blue
        case 5: return .purple
        case 6: return .teal
        case 7: return nil          // "white" — default label color
        default: return nil
        }
    }
}
