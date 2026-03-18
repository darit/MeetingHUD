import Foundation

/// Lightweight web search using DuckDuckGo Instant Answer API.
/// No API key needed. Returns quick summaries and related topics.
actor WebSearchManager {

    struct SearchResult: Sendable {
        let query: String
        let abstract: String
        let source: String
        let sourceURL: String
        let relatedTopics: [String]
        let answer: String
    }

    /// Cache to avoid duplicate searches.
    private var cache: [String: SearchResult] = [:]

    /// Whether web search is enabled (user preference).
    private(set) var isEnabled: Bool = false

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "webSearchEnabled")
    }

    func restoreSettings() {
        isEnabled = UserDefaults.standard.bool(forKey: "webSearchEnabled")
    }

    /// Search DuckDuckGo for quick context about a topic.
    func search(query: String) async -> SearchResult? {
        guard isEnabled else { return nil }

        // Check cache
        let cacheKey = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = cache[cacheKey] { return cached }

        // Build URL
        guard var components = URLComponents(string: "https://api.duckduckgo.com/") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            let abstract = json?["AbstractText"] as? String ?? ""
            let source = json?["AbstractSource"] as? String ?? ""
            let sourceURL = json?["AbstractURL"] as? String ?? ""
            let answer = json?["Answer"] as? String ?? ""

            var relatedTopics: [String] = []
            if let topics = json?["RelatedTopics"] as? [[String: Any]] {
                for topic in topics.prefix(5) {
                    if let text = topic["Text"] as? String, !text.isEmpty {
                        relatedTopics.append(text)
                    }
                }
            }

            // Skip empty results
            guard !abstract.isEmpty || !answer.isEmpty || !relatedTopics.isEmpty else { return nil }

            let result = SearchResult(
                query: query,
                abstract: abstract,
                source: source,
                sourceURL: sourceURL,
                relatedTopics: relatedTopics,
                answer: answer
            )

            cache[cacheKey] = result
            return result
        } catch {
            print("[WebSearch] Failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Format search results as context for LLM prompts.
    func formatForPrompt(_ result: SearchResult) -> String {
        var parts: [String] = []

        if !result.answer.isEmpty {
            parts.append("Quick answer: \(result.answer)")
        }
        if !result.abstract.isEmpty {
            parts.append("Summary: \(result.abstract)")
            if !result.source.isEmpty {
                parts.append("Source: \(result.source)")
            }
        }
        if !result.relatedTopics.isEmpty {
            parts.append("Related: \(result.relatedTopics.prefix(3).joined(separator: "; "))")
        }

        return parts.joined(separator: "\n")
    }

    /// Clear the search cache.
    func clearCache() {
        cache.removeAll()
    }
}
