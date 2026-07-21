import Foundation
import CoreGraphics
import AppKit

/// Listen-only `CGEventTap` that records mouse movement, drags, clicks and scrolls
/// with host-clock timestamps, on a dedicated background run-loop thread so it never
/// stutters the UI.
///
/// Requires Accessibility permission. Coordinates are captured in global display
/// points (top-left origin); timestamps are raw `HostClock.now()` seconds and are
/// rebased onto the video timeline by the recorder once the first frame's host time
/// is known.
final class EventTap: @unchecked Sendable {

    /// A captured input sample, still in the raw host-clock domain.
    struct RawSample {
        var hostTime: Double
        var type: RecordingEventType
        var x: Double
        var y: Double
    }

    private let lock = NSLock()
    private var samples: [RawSample] = []

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    private(set) var isRunning = false

    // MARK: Lifecycle

    /// Starts the tap on its own thread. Returns false if the tap couldn't be created
    /// (usually missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let interestedTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel,
            .keyDown
        ]
        let mask: CGEventMask = interestedTypes.reduce(CGEventMask(0)) { acc, type in
            acc | (CGEventMask(1) << CGEventMask(type.rawValue))
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            return false
        }

        tapPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source

        let thread = Thread { [weak self] in
            guard let self else { return }
            let rl = CFRunLoopGetCurrent()
            self.threadRunLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            // Keep the run loop alive until stop() cancels this thread. Check the
            // current thread's own flag — never `self.thread`, which stop() nils out.
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
        }
        thread.name = "com.andrea.mydemostudio.eventtap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        isRunning = true
        thread.start()
        return true
    }

    /// Stops the tap and returns everything captured so far, still in host-clock time.
    @discardableResult
    func stop() -> [RawSample] {
        guard isRunning else { return drain() }
        isRunning = false

        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let rl = threadRunLoop, let source = runLoopSource {
            CFRunLoopRemoveSource(rl, source, .commonModes)
            CFRunLoopStop(rl)
        }
        thread?.cancel()
        thread = nil
        threadRunLoop = nil
        runLoopSource = nil
        tapPort = nil

        return drain()
    }

    // MARK: Sample intake (called from the tap thread)

    fileprivate func record(type: RecordingEventType, location: CGPoint) {
        let sample = RawSample(
            hostTime: HostClock.now(),
            type: type,
            x: Double(location.x),
            y: Double(location.y)
        )
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    fileprivate func reEnableTapIfNeeded() {
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    private func drain() -> [RawSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

/// C-compatible trampoline. Mouse coordinates are recorded directly from the event;
/// the tap is re-enabled if the system disables it (timeout / user input overload).
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        tap.reEnableTapIfNeeded()
        return Unmanaged.passUnretained(event)
    default:
        break
    }

    if let mapped = mapEventType(type) {
        tap.record(type: mapped, location: event.location)
    }
    return Unmanaged.passUnretained(event)
}

private func mapEventType(_ type: CGEventType) -> RecordingEventType? {
    switch type {
    case .mouseMoved:        return .mouseMoved
    case .leftMouseDown:     return .leftMouseDown
    case .leftMouseUp:       return .leftMouseUp
    case .rightMouseDown:    return .rightMouseDown
    case .rightMouseUp:      return .rightMouseUp
    case .leftMouseDragged,
         .rightMouseDragged,
         .otherMouseDragged: return .drag
    case .scrollWheel:       return .scroll
    case .keyDown:           return .keyDown
    default:                 return nil
    }
}
