import SwiftUI

/// A simplified, code-drawn approximation of the Claude brand mark, not an official logo.
struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        for index in 0..<12 {
            let angle = Double(index) * .pi / 6
            let perpendicular = angle + .pi / 2
            let innerRadius = radius * 0.23
            let outerRadius = radius * 0.92
            let halfWidth = radius * 0.10

            path.move(to: point(center, innerRadius, angle - 0.08))
            path.addLine(to: point(center, outerRadius, angle, halfWidth, perpendicular))
            path.addLine(to: point(center, outerRadius, angle, -halfWidth, perpendicular))
            path.closeSubpath()
        }

        path.addEllipse(
            in: CGRect(
                x: center.x - radius * 0.25,
                y: center.y - radius * 0.25,
                width: radius * 0.5,
                height: radius * 0.5))
        return path
    }

    private func point(
        _ center: CGPoint,
        _ radius: CGFloat,
        _ angle: Double,
        _ offset: CGFloat = 0,
        _ perpendicular: Double = 0
    ) -> CGPoint {
        CGPoint(
            x: center.x + radius * cos(angle) + offset * cos(perpendicular),
            y: center.y + radius * sin(angle) + offset * sin(perpendicular))
    }
}

/// A simplified, code-drawn approximation of the Codex brand mark, not an official logo.
struct CodexMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        for index in 0..<6 {
            let angle = Double(index) * .pi / 3 - .pi / 2
            let tangent = angle + .pi / 2
            let inner = point(center, radius * 0.18, angle)
            let outer = point(center, radius * 0.90, angle)
            let left = point(outer, radius * 0.38, tangent)
            let right = point(outer, -radius * 0.38, tangent)

            path.move(to: inner)
            path.addCurve(
                to: left,
                control1: point(inner, radius * 0.42, tangent),
                control2: point(left, -radius * 0.30, angle))
            path.addCurve(
                to: right,
                control1: point(left, radius * 0.38, angle),
                control2: point(right, radius * 0.38, angle))
            path.addCurve(
                to: inner,
                control1: point(right, -radius * 0.30, angle),
                control2: point(inner, -radius * 0.42, tangent))
        }
        return path
    }

    private func point(_ origin: CGPoint, _ distance: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(
            x: origin.x + distance * cos(angle),
            y: origin.y + distance * sin(angle))
    }
}

struct ClaudeMarkView: View {
    var body: some View {
        ClaudeMark()
            .fill(.foreground)
            .frame(width: 12, height: 12)
    }
}

struct CodexMarkView: View {
    var body: some View {
        CodexMark()
            .stroke(.foreground, style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
            .frame(width: 12, height: 12)
    }
}
