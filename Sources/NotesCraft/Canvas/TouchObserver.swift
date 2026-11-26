import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Watches drawing touches without interfering with them, to detect
/// "draw and hold" (snap to a shape) and to know where the pen is.
final class TouchObserver: UIGestureRecognizer {
    /// Called once when the pen has rested in place long enough during a stroke.
    var onHold: (([CGPoint]) -> Void)?
    /// Called when the stroke's touch ends or is cancelled.
    var onEnd: (() -> Void)?
    /// Called when the pen moves on after a hold (the snap is cancelled).
    var onHoldCancelled: (() -> Void)?

    private(set) var points: [CGPoint] = []
    private(set) var heldDuringStroke = false
    private(set) var lastStrokeEndedAt: Date = .distantPast
    private(set) var lastStrokeHeld = false
    private weak var trackedTouch: UITouch?
    private var lastMoveTime: TimeInterval = 0
    private var lastMovePoint: CGPoint = .zero
    private var holdPoint: CGPoint = .zero
    private var holdTimer: Timer?
    var holdDelay: TimeInterval = 0.5
    var trackFingers = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, let touch = touches.first, touches.count == 1 else { return }
        guard touch.type == .pencil || (trackFingers && touch.type == .direct) else { return }
        trackedTouch = touch
        points = [touch.location(in: view)]
        heldDuringStroke = false
        lastMoveTime = touch.timestamp
        lastMovePoint = points[0]
        scheduleHoldCheck()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let coalesced = event.coalescedTouches(for: touch) ?? [touch]
        for t in coalesced { points.append(t.location(in: view)) }
        let p = touch.location(in: view)
        if heldDuringStroke, hypot(p.x - holdPoint.x, p.y - holdPoint.y) > 14 {
            // Moved on after the hold: this is a normal stroke again.
            heldDuringStroke = false
            onHoldCancelled?()
        }
        if hypot(p.x - lastMovePoint.x, p.y - lastMovePoint.y) > 3.5 {
            lastMovePoint = p
            lastMoveTime = touch.timestamp
            if !heldDuringStroke { scheduleHoldCheck() }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        guard let touch = trackedTouch, touches.contains(touch) else {
            if trackedTouch == nil { state = .failed }
            return
        }
        holdTimer?.invalidate()
        holdTimer = nil
        trackedTouch = nil
        lastStrokeHeld = heldDuringStroke
        lastStrokeEndedAt = Date()
        onEnd?()
        state = .failed
    }

    override func reset() {
        super.reset()
        holdTimer?.invalidate()
        holdTimer = nil
        trackedTouch = nil
    }

    private func scheduleHoldCheck() {
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.trackedTouch != nil, !self.heldDuringStroke, self.points.count > 4 else { return }
                self.heldDuringStroke = true
                self.holdPoint = self.lastMovePoint
                self.onHold?(self.points)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    /// Whether the stroke that just finished (or is finishing) was held. The
    /// canvas may report the new stroke before or after this recognizer sees the
    /// touch end, so both cases are covered.
    func consumeHold() -> Bool {
        defer {
            lastStrokeHeld = false
            heldDuringStroke = false
        }
        if heldDuringStroke { return true }
        return lastStrokeHeld && Date().timeIntervalSince(lastStrokeEndedAt) < 1.5
    }
}

/// Keeps PencilKit from drawing when the pen taps a control floating over the
/// canvas (selection bar, "Add page"). It recognizes instantly without
/// cancelling the control's own touches, and PencilKit must wait for it to fail.
final class PencilShield: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
    weak var drawingRecognizer: UIGestureRecognizer?

    init(drawingRecognizer: UIGestureRecognizer) {
        self.drawingRecognizer = drawingRecognizer
        super.init(target: nil, action: nil)
        minimumPressDuration = 0
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other === drawingRecognizer
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other !== drawingRecognizer
    }
}
