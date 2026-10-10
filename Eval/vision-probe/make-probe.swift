// Spike S1 probe image (§15 S1, §7.4 capability guard): a 1568×980 screenshot-like image with
// three magenta mark tags (1, 2, 3), each next to a word in small UI-sized text, plus a 4-digit
// order number. The words and number are random per run, so a model can only answer by seeing.
// Usage: make-probe <out.png> <word1> <word2> <word3> <4-digit number>
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 6 else {
    FileHandle.standardError.write(Data("usage: make-probe <out.png> <word1> <word2> <word3> <number>\n".utf8))
    exit(2)
}
let (outputPath, words, number) = (arguments[1], Array(arguments[2...4]), arguments[5])
let (width, height) = (1568, 980)

let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}
func fill(_ x: Int, _ y: Int, _ rectWidth: Int, _ rectHeight: Int, _ fillColor: CGColor) {
    context.setFillColor(fillColor)
    context.fill(CGRect(x: x, y: height - y - rectHeight, width: rectWidth, height: rectHeight))
}
func text(_ string: String, _ x: Int, _ y: Int, size: CGFloat, textColor: CGColor = color(35, 35, 40), bold: Bool = false) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(
            string: string,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
            ]))
    context.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(height - y) - CTFontGetAscent(font))
    CTLineDraw(line, context)
}

// A plain app window so the image looks like a screenshot, not a test card.
fill(0, 0, width, height, color(238, 238, 242))
fill(0, 0, width, 28, color(250, 250, 250))
text("Orders", 16, 6, size: 14, bold: true)
fill(220, 60, 1300, 860, color(255, 255, 255))
text("Recent activity", 250, 84, size: 18, bold: true)
for row in 0..<8 {
    fill(250, 140 + row * 70, 1220, 1, color(225, 225, 230))
    text("Lorem ipsum entry \(row + 1)", 1000, 160 + row * 70, size: 13, textColor: color(150, 150, 155))
}

// Three tagged words in different regions, at 15 px: small, like real UI labels.
let positions = [(300, 190), (760, 470), (420, 750)]
for (index, (x, y)) in positions.enumerated() {
    fill(x, y, 22, 18, color(217, 0, 128))
    text("\(index + 1)", x + 6, y + 2, size: 13, textColor: color(255, 255, 255), bold: true)
    text(words[index], x + 30, y + 1, size: 15)
}
text("Order #\(number)", 1180, 860, size: 15, textColor: color(60, 60, 70))

let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(outputPath)") }
