// Crops a region of a screenshot at native resolution for the zoom pass (§6.2 d).
// Usage: crop <in.png> <out.png> <x> <y> <width> <height>   (native pixels, top-left origin)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 7, let x = Int(arguments[3]), let y = Int(arguments[4]), let width = Int(arguments[5]), let height = Int(arguments[6]) else {
    FileHandle.standardError.write(Data("usage: crop <in.png> <out.png> <x> <y> <width> <height>\n".utf8))
    exit(2)
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let cropped = image.cropping(to: CGRect(x: x, y: y, width: width, height: height))
else { fatalError("cannot crop \(arguments[1])") }
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, cropped, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(arguments[2])") }
