import SwiftUI

/// Presentation-only identity. No timers, capture, or engine state (§3.5, §6.5).
struct ChalkBeacon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: center)
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: center)
        path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: center)
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: center)
        path.closeSubpath()
        return path
    }
}

struct ChalkBrandMark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(DS.Colors.ink)
            ChalkBeacon()
                .fill(DS.Colors.apricot)
                .frame(width: size * 0.62, height: size * 0.62)
            Circle()
                .fill(DS.Colors.paper)
                .frame(width: size * 0.12, height: size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ChalkSectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.8)
            .foregroundStyle(DS.Colors.textTertiary)
    }
}

struct ChalkCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16).stroke(DS.Colors.borderSubtle, lineWidth: 1))
    }
}

extension View {
    func chalkCard() -> some View { modifier(ChalkCardStyle()) }
}
