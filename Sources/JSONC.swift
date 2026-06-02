import Foundation

/// Strips comments from JSONC (JSON-with-comments) so `.stackbar.json` can carry
/// explanatory `//` and `/* */` comments and still parse with JSONSerialization.
/// String contents are preserved (a `//` inside a "string" is not a comment).
/// Also tolerates trailing commas, which are common in hand-edited config.
enum JSONC {
    static func stripComments(_ input: String) -> String {
        var out = String()
        out.reserveCapacity(input.count)

        var inString = false
        var escaped = false
        var inLineComment = false
        var inBlockComment = false

        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : "\0"

            if inLineComment {
                if c == "\n" { inLineComment = false; out.append(c) }
                i += 1
                continue
            }
            if inBlockComment {
                if c == "*" && next == "/" { inBlockComment = false; i += 2; continue }
                i += 1
                continue
            }
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            // Not in string/comment:
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/" && next == "/" { inLineComment = true; i += 2; continue }
            if c == "/" && next == "*" { inBlockComment = true; i += 2; continue }
            out.append(c)
            i += 1
        }

        return removeTrailingCommas(out)
    }

    /// Remove trailing commas before } or ] (JSONSerialization rejects them).
    private static func removeTrailingCommas(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "," {
                // Look ahead past whitespace for a closing bracket.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    i += 1   // drop the comma
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}
