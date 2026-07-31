import AppKit

/// Shift キーを短時間に2回押したことを検知する。
/// 他の修飾キーと同時押し（⇧⌘ などのショートカット）では発火しないよう、
/// 「Shift だけが押された」状態のみカウントする。
@MainActor
final class ShiftDoubleTapMonitor {
    var onDoubleTap: (() -> Void)?

    private let threshold: TimeInterval = 0.4
    private var lastPress: TimeInterval = 0
    private var shiftWasDown = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shiftDown = flags.contains(.shift)

        if shiftDown && !shiftWasDown {
            shiftWasDown = true
            // 押された瞬間に Shift 単独なら、ダブルタップ判定に進む。
            guard flags == .shift else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPress < threshold {
                lastPress = 0
                onDoubleTap?()
            } else {
                lastPress = now
            }
        } else if !shiftDown && shiftWasDown {
            shiftWasDown = false
        }
    }
}
