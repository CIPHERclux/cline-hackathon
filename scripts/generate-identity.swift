import AVFoundation
// Regenerate the original Chalk icon and local introduction using Apple frameworks only.
// Run: swift scripts/generate-identity.swift <absolute repository path>
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let ink = NSColor(srgbRed: 0.188, green: 0.149, blue: 0.220, alpha: 1)
let paper = NSColor(srgbRed: 0.961, green: 0.941, blue: 0.910, alpha: 1)
let coral = NSColor(srgbRed: 0.957, green: 0.714, blue: 0.608, alpha: 1)

func beacon(center: CGPoint, radius: CGFloat) {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: center.x, y: center.y + radius))
    path.curve(
        to: CGPoint(x: center.x + radius, y: center.y), controlPoint1: center, controlPoint2: center
    )
    path.curve(
        to: CGPoint(x: center.x, y: center.y - radius), controlPoint1: center, controlPoint2: center
    )
    path.curve(
        to: CGPoint(x: center.x - radius, y: center.y), controlPoint1: center, controlPoint2: center
    )
    path.curve(
        to: CGPoint(x: center.x, y: center.y + radius), controlPoint1: center, controlPoint2: center
    )
    path.close()
    coral.setFill()
    path.fill()
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let side = CGFloat(size)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    ink.setFill()
    NSBezierPath(
        roundedRect: CGRect(
            x: side * 0.04, y: side * 0.04, width: side * 0.92, height: side * 0.92),
        xRadius: side * 0.22, yRadius: side * 0.22
    ).fill()
    beacon(center: CGPoint(x: side / 2, y: side / 2), radius: side * 0.34)
    paper.setFill()
    NSBezierPath(
        ovalIn: CGRect(x: side * 0.46, y: side * 0.46, width: side * 0.08, height: side * 0.08)
    ).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(
        to: root.appendingPathComponent("Chalk/Assets.xcassets/AppIcon.appiconset/\(size)-mac.png"))
}

let destination = root.appendingPathComponent("Chalk/ChalkIntroduction.mp4")
if FileManager.default.fileExists(atPath: destination.path) {
    try FileManager.default.removeItem(at: destination)
}
let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
let width = 660
let height = 372
let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ])
writer.add(input)
guard writer.startWriting() else {
    fatalError("Cannot start video writer: \(String(describing: writer.error))")
}
writer.startSession(atSourceTime: .zero)
let slides = [
    ("A little clarity.", "Meet Chalk, your screen-side guide.", "01 / WELCOME"),
    ("Hold. Ask. Understand.", "Hold Control + Option and ask about your screen.", "02 / TALK"),
    ("See the next step.", "Follow pointers and drawings. You stay in control.", "03 / EXPLORE"),
    ("Make it your own.", "Draw a region, ask a question, or start a walkthrough.", "04 / BEGIN"),
]
func text(_ value: String, at point: CGPoint, font: NSFont, color: NSColor) {
    (value as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}
for frame in 0..<240 {
    while !input.isReadyForMoreMediaData {
        if writer.status == .failed { fatalError("Video writer failed") }
        Thread.sleep(forTimeInterval: 0.005)
    }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    paper.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
    ink.setFill()
    NSBezierPath(
        roundedRect: CGRect(x: 40, y: 270, width: 62, height: 62), xRadius: 18, yRadius: 18
    ).fill()
    beacon(center: CGPoint(x: 71, y: 301), radius: 24)
    let slide = slides[min(frame / 60, 3)]
    text("chalk", at: CGPoint(x: 116, y: 283), font: NSFont(name: "Georgia", size: 38)!, color: ink)
    text(
        slide.2, at: CGPoint(x: 40, y: 232),
        font: .monospacedSystemFont(ofSize: 12, weight: .medium), color: ink)
    text(slide.0, at: CGPoint(x: 40, y: 164), font: NSFont(name: "Georgia", size: 39)!, color: ink)
    text(slide.1, at: CGPoint(x: 40, y: 124), font: .systemFont(ofSize: 18), color: ink)
    for index in 0..<4 {
        (index == frame / 60 ? coral : ink.withAlphaComponent(0.12)).setFill()
        NSBezierPath(
            roundedRect: CGRect(x: 40 + index * 146, y: 42, width: 134, height: 5), xRadius: 2.5,
            yRadius: 2.5
        ).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 20))
    else {
        fatalError("Cannot append video frame: \(String(describing: writer.error))")
    }
}
input.markAsFinished()
let completion = DispatchSemaphore(value: 0)
writer.finishWriting { completion.signal() }
completion.wait()
guard writer.status == .completed else {
    fatalError("Video generation failed: \(String(describing: writer.error))")
}
print("Generated seven Chalk icons and the 12-second local introduction.")
