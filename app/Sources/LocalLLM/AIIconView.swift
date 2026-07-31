import AppKit

/// Type to Siriの雰囲気に寄せた、小さな多色AIグリフ。
@MainActor
final class AIIconView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let strokeWidth: CGFloat = 1.6
        let inset = strokeWidth / 2 + 0.5
        let drawingBounds = bounds.insetBy(dx: inset, dy: inset)
        let paths = CGMutablePath()
        paths.addEllipse(in: drawingBounds)

        let wave = CGMutablePath()
        wave.move(to: CGPoint(x: drawingBounds.minX + 1, y: drawingBounds.midY))
        wave.addCurve(
            to: CGPoint(x: drawingBounds.midX, y: drawingBounds.midY),
            control1: CGPoint(x: drawingBounds.minX + 3.5, y: drawingBounds.minY + 2),
            control2: CGPoint(x: drawingBounds.midX - 2.5, y: drawingBounds.minY + 2)
        )
        wave.addCurve(
            to: CGPoint(x: drawingBounds.maxX - 1, y: drawingBounds.midY),
            control1: CGPoint(x: drawingBounds.midX + 2.5, y: drawingBounds.maxY - 2),
            control2: CGPoint(x: drawingBounds.maxX - 3.5, y: drawingBounds.maxY - 2)
        )
        paths.addPath(wave)

        context.saveGState()
        context.addPath(paths)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()

        let colors =
            [
                NSColor.systemPink.cgColor,
                NSColor.systemPurple.cgColor,
                NSColor.systemBlue.cgColor,
                NSColor.systemTeal.cgColor,
                NSColor.systemOrange.cgColor,
            ] as CFArray
        let locations: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: bounds.minX, y: bounds.minY),
                end: CGPoint(x: bounds.maxX, y: bounds.maxY),
                options: []
            )
        }
        context.restoreGState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
