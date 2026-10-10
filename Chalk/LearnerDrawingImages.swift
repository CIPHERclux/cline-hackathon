//
//  LearnerDrawingImages.swift
//  Chalk
//
//  §4.2.5 "context to the model": the learner's ⌃⌥ strokes are drawn onto the screenshot copy
//  the model sees, the region they mark goes along as a native-resolution crop, and the prompt
//  says what the learner circled. Nothing is written to disk (§10.1).
//

import AppKit
import ChalkCore

enum LearnerDrawingImages {
    /// §5.6 learner role.
    static var learnerInk: CGColor { AnnotationColorRole.learner.color.cgColor }
    /// Extra room around the region, so the crop shows what the stroke sits on.
    static let cropPaddingInPoints: CGFloat = 12

    /// The strokes (display points, top-left origin) in dusty rose on the model image, with
    /// everything outside the marked region dimmed so the model talks about that region (the
    /// owner found answers wandering over the rest of the screen).
    static func drawing(
        _ strokes: [[CGPoint]], region: CGRect, onto image: CGImage, screenSpace: ScreenSpace
    ) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: imageRect)
        // Display points → image pixels; the context's origin is bottom-left.
        let scaleX = CGFloat(image.width) / screenSpace.displayFrameInAppKitGlobal.width
        let scaleY = CGFloat(image.height) / screenSpace.displayFrameInAppKitGlobal.height
        let padded = region.insetBy(dx: -cropPaddingInPoints, dy: -cropPaddingInPoints)
        let regionInImage = CGRect(
            x: padded.minX * scaleX, y: imageRect.height - padded.maxY * scaleY,
            width: padded.width * scaleX, height: padded.height * scaleY)
        context.saveGState()
        context.addRect(imageRect)
        context.addRect(regionInImage)
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.fillPath(using: .evenOdd)
        context.restoreGState()
        context.setStrokeColor(learnerInk)
        context.setLineWidth(max(3, 3 * scaleX))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            context.move(to: CGPoint(x: first.x * scaleX, y: imageRect.height - first.y * scaleY))
            for point in stroke.dropFirst() {
                context.addLine(
                    to: CGPoint(x: point.x * scaleX, y: imageRect.height - point.y * scaleY))
            }
            context.strokePath()
        }
        return context.makeImage()
    }

    /// The marked region at native resolution, as JPEG.
    static func regionCrop(_ region: CGRect, from nativeImage: CGImage, screenSpace: ScreenSpace)
        -> Data?
    {
        let padded = region.insetBy(dx: -cropPaddingInPoints, dy: -cropPaddingInPoints)
        let nativeRect = screenSpace.displayPointRectToNativePixels(padded)
            .intersection(CGRect(x: 0, y: 0, width: nativeImage.width, height: nativeImage.height))
        guard !nativeRect.isNull, let crop = nativeImage.cropping(to: nativeRect.integral) else {
            return nil
        }
        return MarksImageRenderer.jpegData(crop)
    }

    /// The line that tells the model what the learner did (§4.2.5 "the learner circled region R
    /// (crop attached) while saying …").
    static func contextLine(for stroke: LearnerStroke, screenSpace: ScreenSpace) -> String {
        let width = screenSpace.displayFrameInAppKitGlobal.width
        let height = screenSpace.displayFrameInAppKitGlobal.height
        func norm(_ value: CGFloat, _ extent: CGFloat) -> Int {
            Int((value / extent * 1000).rounded())
        }
        let what =
            stroke.kind == .lasso
            ? "circled a region"
            : "marked an area (an underline or a scribble)"
        return """
            <context>
            While asking, the learner \(what), drawn in dusty rose on the screenshot; the rest of \
            the screen is dimmed. The second image is that region at full resolution. In 0-1000 \
            screenshot coordinates it spans x \(norm(stroke.region.minX, width))-\(norm(stroke.region.maxX, width)), \
            y \(norm(stroke.region.minY, height))-\(norm(stroke.region.maxY, height)). \
            The question is about that region only: "this" and "here" mean it. Explain what is \
            inside it, and point or draw only inside it.
            </context>
            """
    }
}
