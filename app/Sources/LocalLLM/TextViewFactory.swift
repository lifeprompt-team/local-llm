import AppKit

/// `NSTextViewDelegate`に加え、リンク上のmouseDownを直接拾う読み取り専用TextView。
/// 非アクティブ化しないフローティングパネルでもリンクを確実に1クリックで実行する。
@MainActor
final class ActionTextView: NSTextView {
    var onLinkClick: ((Any) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if let link = link(at: event), onLinkClick?(link) == true {
            return
        }
        super.mouseDown(with: event)
    }

    private func link(at event: NSEvent) -> Any? {
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        let localPoint = convert(event.locationInWindow, from: nil)
        let containerOrigin = textContainerOrigin
        let containerPoint = NSPoint(
            x: localPoint.x - containerOrigin.x,
            y: localPoint.y - containerOrigin.y
        )
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }

        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length else { return nil }
        return textStorage.attribute(.link, at: characterIndex, effectiveRange: nil)
    }
}

@MainActor
enum TextViewFactory {
    /// スクロール可能な NSTextView を、描画に必要な設定を揃えて生成する。
    /// （minSize/maxSize/containerSize/isHorizontallyResizable を正しく設定しないと
    ///  テキストが storage に入っても表示されないことがある）
    static func make(
        frame: NSRect,
        editable: Bool,
        fontSize: CGFloat,
        bordered: Bool
    ) -> (scroll: NSScrollView, textView: NSTextView) {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = bordered ? .bezelBorder : .noBorder

        let contentSize = scroll.contentSize
        let textView = ActionTextView(frame: NSRect(origin: .zero, size: contentSize))
        let bigValue = CGFloat.greatestFiniteMagnitude
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: bigValue, height: bigValue)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: bigValue
        )
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = editable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scroll.documentView = textView
        return (scroll, textView)
    }
}
