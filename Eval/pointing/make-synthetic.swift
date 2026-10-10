// Draws a synthetic "design app" screenshot at Retina size (2880×1800) with known element boxes,
// so the pointing check can be validated before real demo screenshots exist.
// Usage: swift Eval/pointing/make-synthetic.swift Eval/pointing/fixtures/synthetic-editor.png
// Prints the ground-truth boxes (top-left pixel coordinates) as JSON on stdout.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvasWidth = 2880
let canvasHeight = 1800
let outputPath = CommandLine.arguments.dropFirst().first ?? "synthetic-editor.png"

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no context") }

var groundTruthBoxes: [String: [Int]] = [:]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

// All helpers take top-left coordinates; CoreGraphics is bottom-left.
func flippedRect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> CGRect {
    CGRect(x: x, y: canvasHeight - y - height, width: width, height: height)
}

func fill(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ fillColor: CGColor, radius: CGFloat = 0) {
    context.setFillColor(fillColor)
    let path = CGPath(roundedRect: flippedRect(x, y, width, height), cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(path)
    context.fillPath()
}

func stroke(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ strokeColor: CGColor, radius: CGFloat = 0, lineWidth: CGFloat = 2) {
    context.setStrokeColor(strokeColor)
    context.setLineWidth(lineWidth)
    let path = CGPath(roundedRect: flippedRect(x, y, width, height), cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(path)
    context.strokePath()
}

@discardableResult
func text(_ string: String, _ x: Int, _ y: Int, size: CGFloat = 28, textColor: CGColor = color(30, 30, 30), bold: Bool = false) -> [Int] {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    let bounds = CTLineGetTypographicBounds(line, nil, nil, nil)
    let ascent = CTFontGetAscent(font)
    context.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(canvasHeight - y) - ascent)
    CTLineDraw(line, context)
    return [x, y, Int(bounds.rounded()), Int((ascent + CTFontGetDescent(font)).rounded())]
}

// Window background
fill(0, 0, canvasWidth, canvasHeight, color(236, 236, 240))

// Menu bar
fill(0, 0, canvasWidth, 48, color(250, 250, 250))
var menuX = 40
for (index, title) in ["Chalk Studio", "File", "Edit", "View", "Window", "Help"].enumerated() {
    let box = text(title, menuX, 10, size: 26, bold: index == 0)
    if title == "Edit" { groundTruthBoxes["edit_menu"] = box }
    menuX += box[2] + 48
}

// Toolbar with labelled buttons, an icon-only gear and a zoom readout
fill(0, 48, canvasWidth, 100, color(244, 244, 246))
var buttonX = 480
for title in ["New", "Open", "Save", "Export", "Share"] {
    fill(buttonX, 72, 150, 52, color(255, 255, 255), radius: 10)
    stroke(buttonX, 72, 150, 52, color(200, 200, 205), radius: 10)
    let labelBox = text(title, buttonX + 75 - title.count * 8, 84, size: 26)
    if title == "Export" { groundTruthBoxes["export_button"] = [buttonX, 72, 150, 52]; _ = labelBox }
    buttonX += 172
}
let zoomBox = text("125%", 2420, 84, size: 26)
groundTruthBoxes["zoom_readout"] = zoomBox
// Gear icon (no text): ring with spokes
let gearCenter = CGPoint(x: 2700, y: CGFloat(canvasHeight) - 98)
context.setStrokeColor(color(90, 90, 100))
context.setLineWidth(6)
context.strokeEllipse(in: CGRect(x: gearCenter.x - 18, y: gearCenter.y - 18, width: 36, height: 36))
for spoke in 0..<8 {
    let angle = CGFloat(spoke) * .pi / 4
    context.move(to: CGPoint(x: gearCenter.x + cos(angle) * 18, y: gearCenter.y + sin(angle) * 18))
    context.addLine(to: CGPoint(x: gearCenter.x + cos(angle) * 28, y: gearCenter.y + sin(angle) * 28))
}
context.strokePath()
groundTruthBoxes["gear_icon"] = [2700 - 30, 98 - 30, 60, 60]

// Layers sidebar
fill(0, 148, 440, canvasHeight - 148, color(248, 248, 250))
text("Layers", 32, 176, size: 30, bold: true)
var layerY = 250
for name in ["Background", "Title text", "Logo", "Photo frame"] {
    fill(20, layerY - 12, 400, 60, color(255, 255, 255), radius: 8)
    let box = text(name, 48, layerY, size: 26)
    if name == "Logo" { groundTruthBoxes["logo_layer"] = [20, layerY - 12, 400, 60]; _ = box }
    layerY += 76
}
// Icon-only "add layer" button: a plus in a rounded square
fill(32, 1690, 64, 64, color(255, 255, 255), radius: 10)
stroke(32, 1690, 64, 64, color(190, 190, 195), radius: 10)
fill(61, 1704, 6, 36, color(70, 70, 80))
fill(46, 1719, 36, 6, color(70, 70, 80))
groundTruthBoxes["add_layer_button"] = [32, 1690, 64, 64]

// Canvas with shapes
fill(500, 200, 1780, 1540, color(255, 255, 255))
context.setFillColor(color(220, 50, 50))
context.fillEllipse(in: flippedRect(800, 500, 260, 260))
groundTruthBoxes["red_circle"] = [800, 500, 260, 260]
fill(1300, 600, 300, 300, color(50, 110, 220))
context.setFillColor(color(60, 170, 90))
context.move(to: CGPoint(x: 1900, y: CGFloat(canvasHeight - 1300)))
context.addLine(to: CGPoint(x: 2150, y: CGFloat(canvasHeight - 1300)))
context.addLine(to: CGPoint(x: 2025, y: CGFloat(canvasHeight - 1080)))
context.fillPath()

// Inspector
fill(2320, 148, 560, canvasHeight - 148, color(248, 248, 250))
text("Inspector", 2350, 176, size: 30, bold: true)
text("Opacity", 2350, 260, size: 26)
fill(2350, 310, 480, 8, color(210, 210, 215), radius: 4)
fill(2700, 300, 28, 28, color(80, 120, 230), radius: 14)
text("Blend mode", 2350, 380, size: 26)
fill(2350, 424, 480, 56, color(255, 255, 255), radius: 8)
stroke(2350, 424, 480, 56, color(200, 200, 205), radius: 8)
text("Normal", 2370, 438, size: 26)
text("▾", 2790, 436, size: 26)
groundTruthBoxes["blend_dropdown"] = [2350, 424, 480, 56]

guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot write \(outputPath)") }
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)

let json = try JSONSerialization.data(withJSONObject: groundTruthBoxes, options: [.sortedKeys, .prettyPrinted])
print(String(decoding: json, as: UTF8.self))
