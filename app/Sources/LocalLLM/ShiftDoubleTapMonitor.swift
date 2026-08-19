import AppKit

/// Shift キーを短時間に2回押したことと、2回目の長押しを検知する。
/// 他の修飾キーと同時押し（⇧⌘ などのショートカット）では発火しないよう、
/// 「Shift だけが押された」状態のみカウントする。
@MainActor
final class ShiftDoubleTapMonitor {
    var onDoubleTap: (() -> Void)?
    var onDoubleTapHold: (() -> Void)?

    private var recognizer = ShiftDoubleTapRecognizer()
    private var holdTask: Task<Void, Never>?
    private var didTriggerHold = false
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
        let transition = recognizer.update(
            shiftDown: shiftDown,
            hasOtherModifiers: !flags.subtracting(.shift).isEmpty,
            at: ProcessInfo.processInfo.systemUptime
        )

        switch transition {
        case .none:
            break
        case .secondPressBegan:
            scheduleHoldRecognition()
        case .secondPressCancelled:
            cancelHoldRecognition()
        case .secondPressReleased:
            holdTask?.cancel()
            holdTask = nil
            if !didTriggerHold { onDoubleTap?() }
            didTriggerHold = false
        }
    }

    private func scheduleHoldRecognition() {
        holdTask?.cancel()
        didTriggerHold = false
        holdTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, self.recognizer.isSecondPressDown else { return }
            self.didTriggerHold = true
            self.onDoubleTapHold?()
        }
    }

    private func cancelHoldRecognition() {
        holdTask?.cancel()
        holdTask = nil
        didTriggerHold = false
    }
}

enum ShiftDoubleTapTransition: Equatable {
    case none
    case secondPressBegan
    case secondPressCancelled
    case secondPressReleased
}

/// NSEventやタイマーに依存しない、ダブルShift判定の状態機械。
struct ShiftDoubleTapRecognizer {
    let threshold: TimeInterval
    private var lastPressAt: TimeInterval = 0
    private var shiftWasDown = false
    private(set) var isSecondPressDown = false

    init(threshold: TimeInterval = 0.4) {
        self.threshold = threshold
    }

    mutating func update(
        shiftDown: Bool,
        hasOtherModifiers: Bool,
        at now: TimeInterval
    ) -> ShiftDoubleTapTransition {
        if shiftDown && !shiftWasDown {
            shiftWasDown = true
            guard !hasOtherModifiers else {
                lastPressAt = 0
                isSecondPressDown = false
                return .none
            }

            if lastPressAt > 0, now - lastPressAt < threshold {
                lastPressAt = 0
                isSecondPressDown = true
                return .secondPressBegan
            }

            lastPressAt = now
            isSecondPressDown = false
            return .none
        }

        if shiftDown && shiftWasDown {
            guard !hasOtherModifiers else {
                lastPressAt = 0
                let wasSecondPress = isSecondPressDown
                isSecondPressDown = false
                return wasSecondPress ? .secondPressCancelled : .none
            }
            return .none
        }

        if !shiftDown && shiftWasDown {
            shiftWasDown = false
            let wasSecondPress = isSecondPressDown
            isSecondPressDown = false
            if hasOtherModifiers { lastPressAt = 0 }
            return wasSecondPress ? .secondPressReleased : .none
        }

        if !shiftDown && hasOtherModifiers { lastPressAt = 0 }
        return .none
    }
}
