import Foundation

public enum SidebandRichTextRenderer {
    public static func attributed(_ body: String, renderer: Message.Renderer) -> AttributedString? {
        guard body.utf8.count <= SidebandMessageLimits.maximumTextBytes else { return nil }
        switch renderer {
        case .plain: return AttributedString(body)
        case .markdown: return try? AttributedString(markdown: body)
        case .bbcode: return try? AttributedString(markdown: bbcodeToMarkdown(body))
        case .micron: return try? AttributedString(markdown: micronToMarkdown(body))
        }
    }

    public static func bbcodeToMarkdown(_ input: String) -> String {
        var value = input
        let replacements = [
            (#"\[b\](.*?)\[/b\]"#, "**$1**"), (#"\[i\](.*?)\[/i\]"#, "*$1*"),
            (#"\[s\](.*?)\[/s\]"#, "~~$1~~"), (#"\[code\](.*?)\[/code\]"#, "`$1`"),
            (#"\[url=(https?://[^\]\s]+)\](.*?)\[/url\]"#, "[$2]($1)")
        ]
        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        // Unknown tags remain visible instead of being interpreted as active content.
        return value
    }

    public static func micronToMarkdown(_ input: String) -> String {
        input.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let text = String(line)
            if text.hasPrefix("### ") || text.hasPrefix("## ") || text.hasPrefix("# ") || text.hasPrefix("> ") || text.hasPrefix("- ") { return text }
            if text.hasPrefix("! ") { return "**\(text.dropFirst(2))**" }
            return text
        }.joined(separator: "\n")
    }
}
