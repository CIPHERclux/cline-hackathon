//
//  LatexLineView.swift
//  Chalk
//
//  One typeset math line for the whiteboard (D61): SwiftMath (MIT, pinned 1.7.3) renders LaTeX
//  natively, with fractions, roots, integrals and scripts, in Euler, Zapf's handwritten-style
//  math face, so it reads like chalk. Sizes are measured with the same label that draws them.
//

import AppKit
import SwiftMath
import SwiftUI

struct LatexLineView: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat

    // Keep native math labels aligned with the SwiftUI paper board (§5.6, D80).
    static var chalkColor: NSColor { NSColor(WhiteboardView.chalkColor) }

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        Self.configure(label, latex: latex, fontSize: fontSize)
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        Self.configure(label, latex: latex, fontSize: fontSize)
    }

    /// The typeset size, or nil when SwiftMath can't parse the line (the board then falls back
    /// to chalk text).
    static func size(of latex: String, fontSize: CGFloat) -> CGSize? {
        let label = MTMathUILabel()
        configure(label, latex: latex, fontSize: fontSize)
        guard label.error == nil else { return nil }
        // On macOS SwiftMath sizes through `fittingSize` (its intrinsicContentSize is unset).
        let size = label.fittingSize
        return size.width > 0 && size.height > 0
            ? CGSize(width: ceil(size.width), height: ceil(size.height)) : nil
    }

    private static func configure(_ label: MTMathUILabel, latex: String, fontSize: CGFloat) {
        label.font = MTFontManager.manager.eulerFont(withSize: fontSize)
        label.textColor = chalkColor
        label.labelMode = .display
        label.displayErrorInline = false
        label.latex = latex
        label.invalidateIntrinsicContentSize()
    }
}
