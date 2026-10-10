import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws a scripted screen as a plain macOS-like screenshot, so vision models see the controls
/// where the tree says they are: menu bar, window, controls with their labels, the Dock.
@MainActor
enum ScreenRenderer {
    static func jpeg(world: SimWorld) -> Data? {
        let width = Int(SimWorld.screen.width)
        let height = Int(SimWorld.screen.height)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // Top-left origin, like the accessibility tree.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        fill(context, CGRect(x: 0, y: 0, width: width, height: height), gray: 0.93)
        // Menu bar.
        fill(context, CGRect(x: 0, y: 0, width: width, height: 24), gray: 0.98)
        text(context, " \(world.appName)   File   Edit   View   Window   Help", at: CGPoint(x: 8, y: 5), size: 13, bold: true)
        if let away = world.awayApp {
            fill(context, CGRect(x: 40, y: 60, width: 1300, height: 760), gray: 1)
            text(context, "\(away) — a different app", at: CGPoint(x: 80, y: 100), size: 22, bold: true)
        } else {
            let state = world.resolved(world.visibleStateName)
            if let window = state.window {
                fill(context, CGRect(x: 0, y: 28, width: width, height: 30), gray: 0.86)
                text(context, window, at: CGPoint(x: 600, y: 35), size: 13, bold: true)
            }
            if let url = state.url {
                stroke(context, CGRect(x: 300, y: 62, width: 840, height: 26), gray: 0.6)
                text(context, url, at: CGPoint(x: 310, y: 67), size: 12)
            }
            for node in world.currentNodes { draw(node, world: world, in: context) }
        }
        // Dock.
        let dock = world.scenario.dock ?? []
        if !dock.isEmpty {
            fill(context, CGRect(x: 380, y: 846, width: 680, height: 50), gray: 0.8)
            for node in dock {
                stroke(context, node.rect, gray: 0.4)
                text(context, node.name, at: CGPoint(x: node.rect.minX + 3, y: node.rect.midY - 6), size: 10)
            }
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func draw(_ node: ScenarioNode, world: SimWorld, in context: CGContext) {
        let rect = node.rect
        let enabled = node.enabled ?? true
        switch node.role {
        case "AXWindow", "AXGroup", "AXScrollArea", "AXWebArea":
            fill(context, rect, gray: 1)
            stroke(context, rect, gray: 0.75)
        case "AXSheet":
            fill(context, rect, gray: 0.97)
            stroke(context, rect, gray: 0.3, width: 2)
            if let title = node.title { text(context, title, at: CGPoint(x: rect.minX + 16, y: rect.minY + 14), size: 14, bold: true) }
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox":
            fill(context, rect, gray: 1)
            let focused = world.focusedField == node.name
            stroke(context, rect, gray: focused ? 0.2 : 0.6, width: focused ? 2 : 1)
            let value = world.values[node.name] ?? node.value ?? ""
            if value.isEmpty {
                text(context, node.placeholder ?? node.label ?? node.title ?? "", at: CGPoint(x: rect.minX + 6, y: rect.minY + 6), size: 13, gray: 0.6)
            } else {
                text(context, value, at: CGPoint(x: rect.minX + 6, y: rect.minY + 6), size: 13)
            }
            if let label = node.title, node.placeholder != nil || !value.isEmpty {
                text(context, label, at: CGPoint(x: rect.minX - 70, y: rect.minY + 6), size: 12, gray: 0.35)
            }
        case "AXStaticText", "AXHeading":
            text(context, node.value ?? node.title ?? "", at: CGPoint(x: rect.minX, y: rect.minY + 2), size: node.role == "AXHeading" ? 18 : 13, bold: node.role == "AXHeading")
        case "AXLink":
            text(context, node.name, at: CGPoint(x: rect.minX, y: rect.minY + 4), size: 13, color: (0.1, 0.3, 0.85))
        case "AXImage":
            fill(context, rect, gray: 0.8)
            text(context, node.name, at: CGPoint(x: rect.minX + 6, y: rect.maxY - 20), size: 12)
        case "AXRadioButton", "AXCheckBox":
            stroke(context, CGRect(x: rect.minX, y: rect.midY - 7, width: 14, height: 14), gray: 0.3)
            if node.selected == true { fill(context, CGRect(x: rect.minX + 3, y: rect.midY - 4, width: 8, height: 8), gray: 0.2) }
            text(context, node.name, at: CGPoint(x: rect.minX + 20, y: rect.midY - 7), size: 13)
        case "AXRow", "AXCell":
            fill(context, rect, gray: node.selected == true ? 0.82 : 0.99)
            stroke(context, rect, gray: 0.85)
            text(context, node.name, at: CGPoint(x: rect.minX + 8, y: rect.midY - 7), size: 13)
        default:
            fill(context, rect, gray: enabled ? 0.88 : 0.95)
            stroke(context, rect, gray: 0.55)
            text(context, node.name, at: CGPoint(x: rect.minX + 8, y: rect.midY - 7), size: 13, gray: enabled ? 0 : 0.6)
        }
    }

    private static func fill(_ context: CGContext, _ rect: CGRect, gray: CGFloat) {
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(rect)
    }

    private static func stroke(_ context: CGContext, _ rect: CGRect, gray: CGFloat, width: CGFloat = 1) {
        context.setStrokeColor(gray: gray, alpha: 1)
        context.setLineWidth(width)
        context.stroke(rect)
    }

    private static func text(
        _ context: CGContext, _ string: String, at point: CGPoint, size: CGFloat,
        bold: Bool = false, gray: CGFloat = 0, color: (CGFloat, CGFloat, CGFloat)? = nil
    ) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let rgb = color ?? (gray, gray, gray)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.saveGState()
        // Text draws upright in a flipped context.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: point.x, y: point.y + size)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
