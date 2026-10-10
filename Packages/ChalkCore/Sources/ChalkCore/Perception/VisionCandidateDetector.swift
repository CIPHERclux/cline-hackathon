import CoreGraphics
import Foundation
import Vision

/// Apple Vision on the native-pixel capture (§6.2 b): text lines (accurate OCR), rectangles,
/// and contour blobs in both polarities. Runs fully on-device. Shared by the app and the
/// grounding harness so both measure the same thing.
public enum VisionCandidateDetector {
    /// Control-sized contours: 12–160 px (6–80 pt on Retina), not too elongated.
    static let minimumShapeSide: CGFloat = 12
    static let maximumShapeSide: CGFloat = 160
    static let maximumShapeAspectRatio: CGFloat = 4
    /// Contours run on 512 px tiles: Vision's automatic contrast then adapts to each neighbourhood,
    /// which finds small low-contrast icons (dark-mode toolbars) that a whole-screen pass washes out.
    /// Measured in S05 on 4 icons no candidate covered before: 512 px tiles 4/4 in ~183 ms per
    /// 3024×1964 screen; 768/1024 px tiles 3/4; whole-screen 3/4 and far slower (D48).
    static let contourTileSide = 512
    static let contourTileStride = 448

    public static func detectCandidates(in image: CGImage) throws -> [Candidate] {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        // Vision boxes are normalized with a bottom-left origin.
        func pixelBox(_ normalized: CGRect) -> CGRect {
            CGRect(
                x: normalized.minX * imageWidth, y: (1 - normalized.maxY) * imageHeight,
                width: normalized.width * imageWidth, height: normalized.height * imageHeight)
        }

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false

        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.maximumObservations = 0
        rectangleRequest.minimumAspectRatio = 0.05
        rectangleRequest.minimumSize = 0.01
        rectangleRequest.minimumConfidence = 0.5
        rectangleRequest.quadratureTolerance = 20

        try VNImageRequestHandler(cgImage: image).perform([textRequest, rectangleRequest])

        var candidates: [Candidate] = []
        for observation in textRequest.results ?? [] {
            guard let best = observation.topCandidates(1).first else { continue }
            candidates.append(
                Candidate(
                    kind: .text, text: best.string, box: pixelBox(observation.boundingBox),
                    confidence: Double(best.confidence)))
        }
        for observation in rectangleRequest.results ?? [] {
            candidates.append(
                Candidate(
                    kind: .box, box: pixelBox(observation.boundingBox),
                    confidence: Double(observation.confidence)))
        }
        candidates += tiledShapeCandidates(in: image)
        return candidates
    }

    /// Icon-like blobs (§6.2 b "contour detection"), every nesting level, per tile.
    static func tiledShapeCandidates(in image: CGImage) -> [Candidate] {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var shapes: [Candidate] = []
        var tileTop = 0
        while tileTop < image.height {
            var tileLeft = 0
            while tileLeft < image.width {
                let tile = CGRect(
                    x: tileLeft, y: tileTop, width: contourTileSide, height: contourTileSide
                )
                .intersection(imageBounds)
                if let tileImage = image.cropping(to: tile) {
                    let request = VNDetectContoursRequest()
                    request.contrastAdjustment = 3.0
                    // Automatic pivot, per tile: the part that finds dim icons.
                    request.contrastPivot = nil
                    request.detectsDarkOnLight = false
                    request.maximumImageDimension = contourTileSide
                    try? VNImageRequestHandler(cgImage: tileImage).perform([request])
                    if let observation = request.results?.first {
                        for index in 0..<observation.contourCount {
                            guard let contour = try? observation.contour(at: index) else {
                                continue
                            }
                            let normalized = contour.normalizedPath.boundingBox
                            let box = CGRect(
                                x: tile.minX + normalized.minX * tile.width,
                                y: tile.minY + (1 - normalized.maxY) * tile.height,
                                width: normalized.width * tile.width,
                                height: normalized.height * tile.height)
                            guard box.width >= minimumShapeSide, box.height >= minimumShapeSide,
                                box.width <= maximumShapeSide, box.height <= maximumShapeSide,
                                max(box.width, box.height) / min(box.width, box.height)
                                    <= maximumShapeAspectRatio
                            else { continue }
                            shapes.append(Candidate(kind: .shape, box: box))
                        }
                    }
                }
                tileLeft += contourTileStride
            }
            tileTop += contourTileStride
        }
        return shapes
    }

    /// Vision's first accurate-OCR request loads its model, which took ~24 s cold in S04 testing
    /// (warm: ~150 ms). Calling this at app launch keeps that off the first question (D40).
    public static func warmUp() {
        guard
            let context = CGContext(
                data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = context.makeImage()
        else { return }
        // The whole pipeline once (OCR, rectangles, a contour tile): each request type loads its
        // own model, and only warming OCR left the first real question at ~3.9 s (S05).
        _ = try? detectCandidates(in: image)
    }
}
