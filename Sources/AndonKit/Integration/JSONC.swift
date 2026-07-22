import Foundation

/// Claude Code tolerates comments in `settings.json`, and people use them.
///
/// `JSONSerialization` does not, so a naive read of a commented settings file
/// throws — and an installer that then "helpfully" rewrites the file would
/// silently delete the user's annotations. We strip comments only to *parse*;
/// the write path is separately guarded by a backup.
public enum JSONC {
    /// Remove `//` and `/* */` comments that fall outside string literals.
    public static func stripComments(_ source: String) -> String {
        var output = String()
        output.reserveCapacity(source.count)

        var inString = false
        var isEscaped = false
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]

            if isEscaped {
                output.append(character)
                isEscaped = false
                index = source.index(after: index)
                continue
            }

            if inString {
                if character == "\\" {
                    output.append(character)
                    isEscaped = true
                } else {
                    if character == "\"" { inString = false }
                    output.append(character)
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = source.index(after: index)
                continue
            }

            if character == "/" {
                let next = source.index(after: index)
                if next < source.endIndex {
                    if source[next] == "/" {
                        // Line comment: skip to newline, keeping the newline so
                        // reported error line numbers still line up.
                        while index < source.endIndex, source[index] != "\n" {
                            index = source.index(after: index)
                        }
                        continue
                    }
                    if source[next] == "*" {
                        var scan = source.index(after: next)
                        while scan < source.endIndex {
                            if source[scan] == "*" {
                                let afterStar = source.index(after: scan)
                                if afterStar < source.endIndex, source[afterStar] == "/" {
                                    scan = source.index(after: afterStar)
                                    break
                                }
                            }
                            // Preserve newlines inside block comments for the
                            // same reason.
                            if source[scan] == "\n" { output.append("\n") }
                            scan = source.index(after: scan)
                        }
                        index = scan
                        continue
                    }
                }
            }

            output.append(character)
            index = source.index(after: index)
        }
        return output
    }

    public static func parseObject(_ source: String) throws -> [String: Any] {
        let cleaned = stripComments(source)
        guard let data = cleaned.data(using: .utf8) else {
            throw NSError(domain: "app.andoncord.jsonc", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "settings file is not valid UTF-8",
            ])
        }
        // An empty or whitespace-only file is a legitimate starting state.
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }

        let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let object = parsed as? [String: Any] else {
            throw NSError(domain: "app.andoncord.jsonc", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "settings root is not a JSON object",
            ])
        }
        return object
    }

    /// Detect whether the source carried comments, so callers can warn that a
    /// rewrite will drop them.
    public static func containsComments(_ source: String) -> Bool {
        stripComments(source).replacingOccurrences(of: "\n", with: "")
            != source.replacingOccurrences(of: "\n", with: "")
    }

    public static func serialize(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            // sortedKeys keeps our rewrites diff-stable across installs;
            // without it, dictionary ordering churns the file on every write.
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}
