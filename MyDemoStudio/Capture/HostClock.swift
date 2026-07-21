import Foundation
import Darwin

/// Seconds on the mach host clock — the single time domain that ties input events to
/// video frames.
///
/// Both sides of the sync use this domain:
/// - The event tap stamps each input with `HostClock.now()` at the moment it fires.
/// - ScreenCaptureKit sample presentation timestamps come from `CMClockGetHostTimeClock`,
///   whose `CMTimeGetSeconds` value is the same mach-based "seconds since boot".
///
/// Subtracting the first frame's host time from each event's host time yields the
/// event's position on the master movie timeline.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Current host time in seconds.
    static func now() -> Double {
        let ticks = mach_absolute_time()
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }
}
