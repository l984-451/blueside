/// When the app keeps running out of the front: for a while after a live fix at flying speed, or while a receiver talks.
/// On the ground with no receiver it sleeps as any app does.
public enum BackgroundPolicy {
    /// A groundspeed at or above this counts as flying.
    public static let flyingKt: Double = 30
    /// How long after the last fix at flying speed the app keeps running, so a GPS gap in flight does not end it.
    public static let flyingHold: TimeInterval = 300
    /// A receiver heard within this long still counts as in use.
    public static let receiverWithin: TimeInterval = 60

    /// Until when the app keeps running with nothing new arriving (nil, or a time already past, lets it sleep),
    /// and the time of the latest live fix at flying speed, which the caller keeps and passes back as `lastFast`.
    public static func runsUntil(position: Position?, lastFast: Date?, receiverHeard: Date?,
                                 now: Date) -> (until: Date?, lastFast: Date?) {
        var fast = lastFast
        if let position, (position.groundspeedKt ?? 0) >= flyingKt, !position.isStale(at: now) {
            fast = max(fast ?? position.timestamp, position.timestamp)
        }
        let until = [fast?.addingTimeInterval(flyingHold), receiverHeard?.addingTimeInterval(receiverWithin)]
            .compactMap { $0 }.max()
        return (until, fast)
    }
}
