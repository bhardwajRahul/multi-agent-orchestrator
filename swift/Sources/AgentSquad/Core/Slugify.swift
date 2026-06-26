/// Stable lowercased hyphenated id from a display name; must stay in sync with the persisted agentId. Unicode-aware: "Über Café" → "über-café".
public func slugify(_ name: String) -> String {
    name
        .filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-" }
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: "-")
        .lowercased()
}
