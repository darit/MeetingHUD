import Foundation

/// Robust JSON extractor for LLM output.
/// LLMs sometimes wrap JSON in markdown fences, preamble, or trailing commentary.
enum LLMJSONParser {

    /// Extract and decode a `Decodable` value from potentially messy LLM text.
    static func extract<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let decoder = JSONDecoder()

        // Strategy 1: Try the full text directly
        if let data = text.data(using: .utf8),
           let result = try? decoder.decode(T.self, from: data) {
            return result
        }

        // Strategy 2: Strip markdown code fences
        let stripped = stripCodeFences(text)
        if let data = stripped.data(using: .utf8),
           let result = try? decoder.decode(T.self, from: data) {
            return result
        }

        // Strategy 3: Find first JSON structure (object or array)
        if let extracted = extractJSONSubstring(from: text),
           let data = extracted.data(using: .utf8),
           let result = try? decoder.decode(T.self, from: data) {
            return result
        }

        throw ParseError.noValidJSON(rawText: String(text.prefix(500)))
    }

    enum ParseError: LocalizedError {
        case noValidJSON(rawText: String)

        var errorDescription: String? {
            switch self {
            case .noValidJSON(let raw):
                "Could not extract valid JSON from LLM output: \(raw)"
            }
        }
    }

    // MARK: - Private

    private static func stripCodeFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove opening fence: ```json or ```
        if result.hasPrefix("```") {
            if let newlineIndex = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newlineIndex)...])
            }
        }
        // Remove closing fence
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONSubstring(from text: String) -> String? {
        // Find first `[` or `{` and match to its balanced closing counterpart
        guard let startIndex = text.firstIndex(where: { $0 == "[" || $0 == "{" }) else {
            return nil
        }

        let opener = text[startIndex]
        let closer: Character = opener == "[" ? "]" : "}"

        // Bracket-counting: find the first balanced close
        var depth = 0
        var inString = false
        var escaped = false

        for index in text[startIndex...].indices {
            let char = text[index]

            if escaped {
                escaped = false
                continue
            }
            if char == "\\" && inString {
                escaped = true
                continue
            }
            if char == "\"" {
                inString.toggle()
                continue
            }
            guard !inString else { continue }

            if char == opener { depth += 1 }
            else if char == closer {
                depth -= 1
                if depth == 0 {
                    return String(text[startIndex...index])
                }
            }
        }

        return nil
    }
}
