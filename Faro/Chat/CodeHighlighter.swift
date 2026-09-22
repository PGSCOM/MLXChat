import UIKit
import Highlightr

/// Syntax-colors code blocks with Highlightr (highlight.js running in
/// JavaScriptCore — no WebView, no network). One shared `Highlightr`
/// instance: creating one evaluates the whole highlight.js source into a
/// fresh JS context, real work that shouldn't repeat per code block.
///
/// Theme: gruvbox-dark, picked over highlight.js's louder built-ins
/// (atom-one-dark, dracula, monokai…) because its palette is warm and
/// muted — cream text, dusty amber/orange, sage green — instead of the
/// reflexive saturated blue-purple that would clash with Faro's own warm
/// near-black + amber-lamp palette (`FaroColor`). Its background is
/// dropped in favor of the app's own `faroCard()` surface.
enum CodeHighlighter {
    private static let highlightr: Highlightr? = {
        let highlightr = Highlightr()
        highlightr?.setTheme(to: "gruvbox-dark")
        highlightr?.theme.setCodeFont(.monospacedSystemFont(ofSize: 13, weight: .regular))
        return highlightr
    }()

    // ponytail: `MarkdownText` re-parses the whole message on every
    // streamed token, which would otherwise re-run the JS highlighter on
    // every already-finished code block for the rest of the reply. Cache
    // by (language, code) so a block that stopped changing is highlighted
    // exactly once.
    private static let cache = NSCache<NSString, NSAttributedString>()

    /// `nil` if Highlightr failed to load (its JS and theme ship as
    /// bundled resources, so this shouldn't happen) — callers fall back to
    /// plain monospaced text.
    static func highlight(_ code: String, language: String?) -> AttributedString? {
        let key = "\(language ?? "")\n\(code)" as NSString
        if let cached = cache.object(forKey: key) {
            return AttributedString(cached)
        }
        guard let result = highlightr?.highlight(code, as: language) else { return nil }
        let stripped = NSMutableAttributedString(attributedString: result)
        stripped.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: stripped.length))
        cache.setObject(stripped, forKey: key)
        return AttributedString(stripped)
    }
}
