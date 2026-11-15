import AppKit
import QuartzCore

/// Motion, the way the system moves things: springs described by how long they take to settle (`response`) and how
/// much they overshoot (`dampingRatio`, 1 = none), and Apple's curves for what is not a spring. With Reduce Motion
/// on, everything is a short cross-fade.
enum BoardMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// a quick, settled spring (controls, cards)
    static let snappy = (response: 0.32, damping: 0.86)
    /// a lively one with a little overshoot (things arriving: the capsule, a thumbnail landing)
    static let bouncy = (response: 0.46, damping: 0.72)

    /// Apple's "emphasized" ease (fast out, long settle) and the matching exit (slow start, quick finish)
    static let emphasized = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    static let exit = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

    /// A spring on `keyPath` from → to, with the stiffness and damping that give `response` and `damping`.
    static func spring(_ keyPath: String, from: Any?, to: Any?, response: Double, damping: Double) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = pow(2 * .pi / response, 2)
        a.damping = 4 * .pi * damping / response
        a.initialVelocity = 0
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        return a
    }

    /// A transform that scales a layer about the middle of its top edge (where the capsule grows from), moved up by
    /// `lift`. AppKit layers here are y-up: the top edge is at `bounds.maxY`.
    static func fromTop(_ layer: CALayer, scaleX: CGFloat, scaleY: CGFloat, lift: CGFloat = 0) -> CATransform3D {
        let midX = layer.bounds.midX, top = layer.bounds.maxY
        var t = CATransform3DMakeTranslation(-midX, -top, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(scaleX, scaleY, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(midX, top + lift, 0))
        return t
    }

    /// Fades a view in or out over `duration` with the emphasized curve (used on its own under Reduce Motion).
    static func fade(_ layer: CALayer?, from: Float, to: Float, duration: Double = 0.18, delay: Double = 0) {
        guard let layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
        a.fillMode = .backwards
        a.timingFunction = emphasized
        layer.add(a, forKey: "board-fade")
    }
}
