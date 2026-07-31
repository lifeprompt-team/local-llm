import AppKit

/// パネル外周に載せる静的な多色ボーダー。コンテンツより前面に表示し、操作は透過する。
@MainActor
final class AccentBorderView: NSView {
    var cornerRadius: CGFloat = 20 { didSet { needsLayout = true } }
    var borderWidth: CGFloat = 1 { didSet { needsLayout = true } }

    private let gradient = CAGradientLayer()
    private let ringMask = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.mask = ringMask
        layer?.addSublayer(gradient)
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        gradient.frame = bounds
        ringMask.frame = bounds
        ringMask.fillColor = NSColor.clear.cgColor
        ringMask.strokeColor = NSColor.white.cgColor
        ringMask.lineWidth = borderWidth
        let inset = borderWidth / 2
        ringMask.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: max(0, cornerRadius - inset),
            cornerHeight: max(0, cornerRadius - inset),
            transform: nil
        )

        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateColors() {
        gradient.colors = [
            NSColor.systemPink.withAlphaComponent(0.82).cgColor,
            NSColor.systemPurple.withAlphaComponent(0.78).cgColor,
            NSColor.systemBlue.withAlphaComponent(0.78).cgColor,
            NSColor.systemTeal.withAlphaComponent(0.72).cgColor,
            NSColor.systemOrange.withAlphaComponent(0.80).cgColor,
            NSColor.systemPink.withAlphaComponent(0.82).cgColor,
        ]
    }
}
