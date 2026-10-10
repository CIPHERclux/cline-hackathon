// grounding-marks: runs the app's own perception code (ChalkCore) on a screenshot, for the
// grounding harness (§6.8, Eval/pointing/run.ts). Writes, into <out-directory>:
//   <name>.marks.json  marks (native-pixel boxes) + model-image geometry
//   <name>.model.png   the screenshot at model size (≤ 1568 px long edge)
//   <name>.som.png     the same with numbered set-of-marks tags
// Usage: grounding-marks <screenshot.png> <out-directory>
import ChalkCore
import CoreGraphics
import Foundation
import ImageIO

struct MarksFile: Encodable {
    var imageWidth: Int
    var imageHeight: Int
    var modelWidth: Int
    var modelHeight: Int
    var modelScale: Double
    var candidateCount: Int
    var candidateMilliseconds: Int
    /// Capped marks: what a set-of-marks image shows the model.
    var marks: [Mark]
    /// Uncapped: what a raw point is snapped to (D48).
    var snapMarks: [Mark]
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: grounding-marks <screenshot.png> <out-directory>\n".utf8))
    exit(2)
}
let inputURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2])
let baseName = inputURL.deletingPathExtension().lastPathComponent
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
    let screenshot = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("cannot read \(inputURL.path)\n".utf8))
    exit(1)
}

let nativeSize = CGSize(width: screenshot.width, height: screenshot.height)
// Golden screenshots don't say which display they came from; the geometry only matters for
// scaling here, so a 2× display of matching size stands in.
let screenSpace = ScreenSpace(
    displayFrameInAppKitGlobal: CGRect(
        x: 0, y: 0, width: nativeSize.width / 2, height: nativeSize.height / 2),
    nativePixelSize: nativeSize,
    modelPixelSize: ScreenSpace.modelPixelSize(forNativePixelSize: nativeSize))

let startedAt = Date()
let candidates = try VisionCandidateDetector.detectCandidates(in: screenshot)
let marks = MarkSelection.selectMarks(from: candidates)
let snapMarks = MarkSelection.selectMarks(from: candidates, limits: .unlimited)
let candidateMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)

func write(_ data: Data?, _ name: String) throws {
    guard let data else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
try write(
    MarksImageRenderer.modelImage(from: screenshot, screenSpace: screenSpace).flatMap(
        MarksImageRenderer.pngData), "\(baseName).model.png")
try write(
    MarksImageRenderer.modelImage(from: screenshot, screenSpace: screenSpace, marks: marks).flatMap(
        MarksImageRenderer.pngData),
    "\(baseName).som.png")
let marksFile = MarksFile(
    imageWidth: screenshot.width, imageHeight: screenshot.height,
    modelWidth: Int(screenSpace.modelPixelSize.width),
    modelHeight: Int(screenSpace.modelPixelSize.height),
    modelScale: Double(screenSpace.modelScaleX), candidateCount: candidates.count,
    candidateMilliseconds: candidateMilliseconds, marks: marks, snapMarks: snapMarks)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(marksFile).write(
    to: outputDirectory.appendingPathComponent("\(baseName).marks.json"))

// Tuning aid: CHALK_DUMP_CANDIDATES=1 also writes every raw candidate before selection.
if ProcessInfo.processInfo.environment["CHALK_DUMP_CANDIDATES"] == "1" {
    let rawCandidates = candidates.enumerated().map { index, candidate in
        Mark(id: index, kind: candidate.kind, text: candidate.text, box: candidate.box)
    }
    try encoder.encode(rawCandidates).write(
        to: outputDirectory.appendingPathComponent("\(baseName).candidates.json"))
}

let countsByKind = Dictionary(grouping: marks, by: \.kind.rawValue).mapValues(\.count)
FileHandle.standardError.write(
    Data(
        "\(baseName): \(marks.count) marks \(countsByKind) from \(candidates.count) candidates in \(candidateMilliseconds) ms\n"
            .utf8))
