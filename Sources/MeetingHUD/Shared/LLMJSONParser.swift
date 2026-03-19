import Foundation

/// Robust JSON extractor for LLM output.
/// LLMs sometimes wrap JSON in markdown fences, preamble, or trailing commentary.
enum LLMJSONParser {

    /// Extract and decode a `Decodable` value from potentially messy LLM text.
    /// Handles reasoning/thinking models that output chain-of-thought before JSON.
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

        // Strategy 3: Strip <think>...</think> blocks (reasoning models)
        let withoutThinking = stripThinkingBlocks(text)
        if withoutThinking != text {
            let strippedThinking = stripCodeFences(withoutThinking)
            if let data = strippedThinking.data(using: .utf8),
               let result = try? decoder.decode(T.self, from: data) {
                return result
            }
        }

        // Strategy 4: Find ALL balanced JSON structures and try each
        let candidates = extractAllJSONSubstrings(from: text)
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let result = try? decoder.decode(T.self, from: data) {
                return result
            }
        }

        // Strategy 5: Repair truncated JSON (LLM output cut off mid-array/object)
        if let repaired = repairTruncatedJSON(text),
           let data = repaired.data(using: .utf8),
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

    /// Strip thinking/reasoning blocks from reasoning models.
    /// Handles: <think>...</think>, </think> without opening tag (streamed),
    /// <reasoning>...</reasoning>, and numbered reasoning lists (1. **...**)
    private static func stripThinkingBlocks(_ text: String) -> String {
        var result = text

        // Full <think>...</think> blocks
        if let pattern = try? Regex(#"<think>[\s\S]*?</think>"#) {
            result = result.replacing(pattern, with: "")
        }
        // </think> without opening tag — everything before it is thinking
        if let closeIdx = result.range(of: "</think>") {
            result = String(result[closeIdx.upperBound...])
        }
        // <reasoning>...</reasoning>
        if let pattern = try? Regex(#"<reasoning>[\s\S]*?</reasoning>"#) {
            result = result.replacing(pattern, with: "")
        }
        if let closeIdx = result.range(of: "</reasoning>") {
            result = String(result[closeIdx.upperBound...])
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Attempt to repair truncated JSON by finding the last complete element
    /// and closing any open brackets. Handles cases like:
    ///   `[{"topic": "A", "summary": "B"}, {"topic": "C", "sum`  →  `[{"topic": "A", "summary": "B"}]`
    private static func repairTruncatedJSON(_ text: String) -> String? {
        let cleaned = stripCodeFences(stripThinkingBlocks(text))

        // Find the first [ or {
        guard let startIdx = cleaned.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return nil }
        let opener = cleaned[startIdx]
        let closer: Character = opener == "[" ? "]" : "}"

        let fragment = String(cleaned[startIdx...])

        // For arrays: find the last complete object by looking for the last "}," or "}" that
        // closes a complete element, then close the array
        if opener == "[" {
            // Find positions of all complete top-level objects
            var depth = 0
            var inString = false
            var escaped = false
            var lastCompleteEnd: String.Index?

            for idx in fragment.indices {
                let ch = fragment[idx]
                if escaped { escaped = false; continue }
                if ch == "\\" && inString { escaped = true; continue }
                if ch == "\"" { inString.toggle(); continue }
                guard !inString else { continue }

                if ch == "{" || ch == "[" { depth += 1 }
                else if ch == "}" || ch == "]" {
                    depth -= 1
                    if depth == 1 && ch == "}" {
                        // We just closed a top-level object inside the array
                        lastCompleteEnd = idx
                    }
                    if depth == 0 {
                        // Array was already complete, shouldn't reach here but handle it
                        return nil
                    }
                }
            }

            // Rebuild: everything up to and including the last complete object, then close
            if let end = lastCompleteEnd {
                var repaired = String(fragment[fragment.startIndex...end])
                // Remove any trailing comma
                let trimmed = repaired.trimmingCharacters(in: .whitespacesAndNewlines)
                repaired = trimmed.hasSuffix(",") ? String(trimmed.dropLast()) : trimmed
                repaired += "]"
                return repaired
            }
        }

        // For objects: similar logic — find last complete key-value pair
        if opener == "{" {
            var depth = 0
            var inString = false
            var escaped = false
            var lastComma: String.Index?

            for idx in fragment.indices {
                let ch = fragment[idx]
                if escaped { escaped = false; continue }
                if ch == "\\" && inString { escaped = true; continue }
                if ch == "\"" { inString.toggle(); continue }
                guard !inString else { continue }

                if ch == "{" || ch == "[" { depth += 1 }
                else if ch == "}" || ch == "]" { depth -= 1; if depth == 0 { return nil } }
                else if ch == "," && depth == 1 { lastComma = idx }
            }

            if let comma = lastComma {
                let repaired = String(fragment[fragment.startIndex..<comma]) + "}"
                return repaired
            }
        }

        return nil
    }

    /// Extract ALL balanced JSON structures (objects and arrays) from text.
    /// Returns candidates ordered by length descending (largest/most complete first).
    private static func extractAllJSONSubstrings(from text: String) -> [String] {
        var results: [String] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            guard let startIndex = text[searchStart...].firstIndex(where: { $0 == "[" || $0 == "{" }) else {
                break
            }

            let opener = text[startIndex]
            let closer: Character = opener == "[" ? "]" : "}"

            var depth = 0
            var inString = false
            var escaped = false
            var found = false

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
                        let candidate = String(text[startIndex...index])
                        // Only include if it looks like real JSON (has quotes or digits)
                        if candidate.contains("\"") {
                            results.append(candidate)
                        }
                        searchStart = text.index(after: index)
                        found = true
                        break
                    }
                }
            }

            if !found {
                searchStart = text.index(after: startIndex)
            }
        }

        // Largest first — reasoning models put the real JSON last
        return results.sorted { $0.count > $1.count }
    }
}
