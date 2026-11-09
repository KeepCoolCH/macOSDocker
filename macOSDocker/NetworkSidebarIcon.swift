import SwiftUI

struct NetworkSidebarIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 5.18, y: 6.79))
        path.addLine(to: CGPoint(x: 9.82, y: 4.21))
        path.move(to: CGPoint(x: 5.18, y: 9.21))
        path.addLine(to: CGPoint(x: 9.82, y: 11.79))
        for center in [CGPoint(x: 3, y: 8), CGPoint(x: 12, y: 3), CGPoint(x: 12, y: 13)] {
            path.addEllipse(in: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
