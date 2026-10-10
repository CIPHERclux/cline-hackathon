// Headless visual-token regression check; does not launch Chalk or capture the screen.
// Compile alongside ChalkTheme.swift, ChalkVisualIdentity.swift and AnnotationColorRoles.swift.
import AppKit
import SwiftUI

@main
struct VerifyOverlayIdentity {
    static func main() {
        let expectedColors: [(AnnotationColorRole, Color)] = [
            (.focus, DS.Colors.overlayBeacon), (.explain, DS.Colors.explainInk),
            (.correct, DS.Colors.correctInk), (.mistake, DS.Colors.mistakeInk),
            (.learner, DS.Colors.learnerInk), (.neutral, DS.Colors.paper),
        ]
        for (role, expected) in expectedColors {
            guard let actual = role.color.usingColorSpace(.sRGB),
                let expected = NSColor(expected).usingColorSpace(.sRGB)
            else { fatalError("Cannot resolve \(role) color") }
            precondition(abs(actual.redComponent - expected.redComponent) < 0.001)
            precondition(abs(actual.greenComponent - expected.greenComponent) < 0.001)
            precondition(abs(actual.blueComponent - expected.blueComponent) < 0.001)
            precondition(
                max(actual.redComponent, actual.greenComponent) > actual.blueComponent,
                "Unexpected blue-dominant ink: \(role)")
        }
        precondition(AnnotationColorRole(scriptRole: nil) == .focus)
        precondition(AnnotationColorRole(scriptRole: "unknown") == .focus)
        let beacon = ChalkBeacon().path(in: CGRect(x: 0, y: 0, width: 22, height: 22))
        var curves = 0
        var straightEdges = 0
        beacon.cgPath.applyWithBlock { element in
            if element.pointee.type == .addQuadCurveToPoint { curves += 1 }
            if element.pointee.type == .addLineToPoint { straightEdges += 1 }
        }
        precondition(curves == 4 && straightEdges == 0, "Beacon must not become the old triangle")
        precondition(beacon.boundingRect == CGRect(x: 0, y: 0, width: 22, height: 22))
        print(
            "PASS: six shared screen-ink roles, fallback semantics and four-point beacon geometry")
    }
}
