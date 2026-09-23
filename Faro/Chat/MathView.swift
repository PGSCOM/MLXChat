import SwiftUI
import SwiftMath

/// Wraps SwiftMath's `MTMathUILabel` — a UIKit label with a real LaTeX
/// typesetting engine (fractions, roots, matrices, Greek letters) built on
/// CoreText, no WebView — so a display equation renders as actual math
/// instead of literal `$...$` source. Only display-style equations get
/// this (see `MarkdownBlock.displayEquation`): true inline math mid-
/// sentence would need `Text` to host an arbitrary view, which SwiftUI
/// doesn't support.
///
/// If the LaTeX fails to parse, `MTMathUILabel`'s own `displayErrorInline`
/// (left at its default) draws the parser's error message in place of a
/// blank view, so a malformed equation is never silently empty.
struct MathView: UIViewRepresentable {
    let latex: String
    var fontSize: CGFloat = 18

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.labelMode = .display
        label.textAlignment = .left
        label.fontSize = fontSize
        label.textColor = UIColor(FaroColor.bone)
        label.backgroundColor = .clear
        return label
    }

    func updateUIView(_ view: MTMathUILabel, context: Context) {
        view.latex = latex
        view.fontSize = fontSize
    }
}
