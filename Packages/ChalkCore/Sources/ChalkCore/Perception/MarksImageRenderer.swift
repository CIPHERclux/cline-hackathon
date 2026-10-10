import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws the model images (§6.2 a + c): the screenshot downscaled to the model size, optionally
/// with a numbered magenta tag on each mark (set-of-marks, arXiv 2310.11441). Tags sit above a
/// box's top-left corner, else to its left, and only as a last resort inside it, where they would
/// hide the first letters the model needs to read (D40).
public enum MarksImageRenderer {
    public static func modelImage(
        from screenshot: CGImage, screenSpace: ScreenSpace, marks: [Mark]? = nil
    ) -> CGImage? {
        let width = Int(screenSpace.modelPixelSize.width)
        let height = Int(screenSpace.modelPixelSize.height)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(screenshot, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let marks else { return context.makeImage() }

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 13, nil)
        let modelHeight = Double(height)
        for mark in marks {
            let box = screenSpace.nativePixelRectToModelPixels(mark.box)
            let flippedY = modelHeight - box.minY - box.height
            context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0.6, alpha: 0.9))
            context.setLineWidth(1.5)
            context.stroke(CGRect(x: box.minX, y: flippedY, width: box.width, height: box.height))

            let label = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: "\(mark.id)",
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                            gray: 1, alpha: 1),
                    ]))
            let labelWidth = CTLineGetTypographicBounds(label, nil, nil, nil) + 6
            let labelHeight = 16.0
            let tagLeft: Double
            let tagTop: Double
            if box.minY >= labelHeight {
                (tagLeft, tagTop) = (box.minX, box.minY - labelHeight)
            } else if box.minX >= labelWidth {
                (tagLeft, tagTop) = (
                    box.minX - labelWidth, box.minY + max(0, (box.height - labelHeight) / 2)
                )
            } else {
                (tagLeft, tagTop) = (box.minX, box.minY)
            }
            let tagRect = CGRect(
                x: tagLeft, y: modelHeight - tagTop - labelHeight, width: labelWidth,
                height: labelHeight)
            context.setFillColor(CGColor(red: 0.85, green: 0, blue: 0.5, alpha: 0.95))
            context.fill(tagRect)
            context.textPosition = CGPoint(x: tagRect.minX + 3, y: tagRect.minY + 4)
            CTLineDraw(label, context)
        }
        return context.makeImage()
    }

    /// JPEG for the model (D43: much smaller than PNG).
    public static func jpegData(_ image: CGImage, quality: Double = 0.8) -> Data? {
        encode(
            image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    public static func pngData(_ image: CGImage) -> Data? {
        encode(image, type: .png, properties: [:])
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) -> Data?
    {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
