import AppKit

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
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
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
