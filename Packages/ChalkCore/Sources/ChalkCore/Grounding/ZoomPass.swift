import CoreGraphics
import Foundation

/// §6.2 (d), the demo version: when a target is a guess with nothing to snap to, the grounding
/// slot gets a native-resolution crop around the guess (about 2–3× the model image's detail)
/// and points again inside it. Pure geometry and parsing; the app sends the request.
public enum ZoomPass {
    /// The crop's size on screen, in points.
    public static let cropSizeInPoints = CGSize(width: 360, height: 240)

    /// A crop around `guess` (native pixels), slid inside the display rather than shrunk. Also the
    /// 300×300 pt verification crop (§6.2 f).
    public static func cropRect(
        around guess: CGPoint, screenSpace: ScreenSpace, sizeInPoints: CGSize = cropSizeInPoints
    ) -> CGRect {
        let size = CGSize(
            width: min(
                sizeInPoints.width * screenSpace.backingScale, screenSpace.nativePixelSize.width
            ),
            height: min(
                sizeInPoints.height * screenSpace.backingScale,
                screenSpace.nativePixelSize.height))
        let originX = min(
            max(guess.x - size.width / 2, 0), screenSpace.nativePixelSize.width - size.width)
        let originY = min(
            max(guess.y - size.height / 2, 0), screenSpace.nativePixelSize.height - size.height)
        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    /// A 0–1000 answer about the crop → native pixels of the display.
    public static func nativePoint(fromNorm1000 point: CGPoint, in crop: CGRect) -> CGPoint {
        CGPoint(
            x: crop.minX + min(max(point.x, 0), 1000) / 1000 * crop.width,
            y: crop.minY + min(max(point.y, 0), 1000) / 1000 * crop.height)
    }

    /// The question for the grounding slot. The reply is Teaching Script (the rules apply to
    /// every session), so it asks for a single `point` line.
    public static func prompt(lookingFor description: String) -> String {
        """
        This image is a zoomed-in crop of the learner's screen. Find: \(description).
        Reply with exactly two lines: {"type":"point","target":{"px":[x,y],"space":"norm1000"}} \
        with x and y from 0 to 1000 across THIS image, then {"type":"end"}. \
        If it is not in the image, reply only {"type":"end"}.
        """
    }

    /// The first `point` or `draw` target with coordinates in the reply.
    public static func pointedNorm1000(in reply: String) -> CGPoint? {
        var parser = StreamingScriptParser()
        let events = parser.feed(reply + "\n") + parser.finish()
        for event in events {
            guard case .action(let action) = event else { continue }
            let target: TargetDescriptor?
            switch action {
            case .point(let point): target = point.target
            case .draw(let draw): target = draw.target ?? draw.to
            default: target = nil
            }
            if case .pixel(let x, let y, _) = target { return CGPoint(x: x, y: y) }
        }
        return nil
    }
}
