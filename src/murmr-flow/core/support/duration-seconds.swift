import Foundation

extension Duration {
    /// Seconds as a `Double`, for display and for arithmetic against `TimeInterval`.
    ///
    /// `ContinuousClock` is used for all timing because it does not jump when the system
    /// clock is adjusted, but its `Duration` has no direct conversion to `TimeInterval`.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
