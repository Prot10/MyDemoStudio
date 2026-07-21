import Foundation
import AppKit
import SwiftUI

/// Debug-only stress harness, run with `MDS_STRESS=1`.
///
/// It hammers the layout path that a split-view divider drag exercises — repeatedly
/// resizing the window while the editor is live — interleaved with real edits, selection
/// changes and transport activity. A crash under this is the same crash a user hits by
/// dragging the sidebar or inspector divider while a project is open.
@MainActor
enum StabilityStress {

    /// Set by the editor so the stress loop can drive real edits.
    static weak var editorModel: TimelineEditorModel?

    static func run(rounds: Int = 60) {
        Task { @MainActor in
            log("stress starting (\(rounds) rounds)")
            try? await Task.sleep(for: .seconds(3))   // let the editor finish loading

            guard let window = NSApplication.shared.windows.first(where: { $0.frame.width > 400 }) else {
                log("FAIL no window to resize")
                exit(2)
            }
            let original = window.frame

            for round in 0..<rounds {
                // Resizing drives the same NSSplitView / hosted-SwiftUI layout pass as
                // dragging a divider, which is where the reported crash happened.
                let shrink = round % 2 == 0
                var frame = original
                frame.size.width = original.width * (shrink ? 0.62 : 1.0)
                frame.size.height = original.height * (shrink ? 0.75 : 1.0)
                window.setFrame(frame, display: true, animate: false)
                try? await Task.sleep(for: .milliseconds(40))

                // Also exercise the divider itself where one exists.
                for split in splitViews(in: window.contentView) {
                    guard split.arrangedSubviews.count > 1 else { continue }
                    let width = split.frame.width
                    split.setPosition(width * (shrink ? 0.22 : 0.34), ofDividerAt: 0)
                }
                try? await Task.sleep(for: .milliseconds(40))

                // `setPosition` only relayouts. A real drag additionally spins AppKit's
                // nested tracking loop inside `-[NSSplitView mouseDown:]`, which is where
                // the reported crash happened, so synthesize an actual drag too.
                await dragAllDividers(in: window, expanding: round % 2 == 0)

                // Hammer the editor itself while layout churns: rapid setting changes
                // (each of which kicks off a composition rebuild), selection changes,
                // seeking, splitting and undo. This is the overlapping-rebuild case.
                if let model = editorModel {
                    let phase = Double(round % 10) / 10
                    model.adjust { $0.defaultLook.zoomScale = 1.0 + phase }
                    model.adjust { $0.defaultLook.paddingFraction = 0.02 + phase * 0.08 }
                    model.pixelsPerSecond = 20 + phase * 200
                    model.seek(to: model.duration * phase)

                    let clips = model.document.tracks.flatMap(\.clips)
                    model.selectedClipID = clips.isEmpty ? nil : clips[round % clips.count].id
                    if round % 7 == 0 { model.splitAtPlayhead() }
                    if round % 7 == 3, model.canUndo { model.undo() }
                    if round % 11 == 0 { model.togglePlay() }
                }

                if round % 10 == 0 { log("round \(round) ok") }
            }

            window.setFrame(original, display: true, animate: false)
            try? await Task.sleep(for: .milliseconds(300))
            log("PASS survived \(rounds) resize/divider rounds")
            exit(0)
        }
    }

    /// Synthesizes press-drag-release across **every** divider of every split view, so
    /// AppKit runs the same nested mouse-tracking loop a user's drag does.
    ///
    /// Dragging only the first split view meant only the sidebar was ever exercised —
    /// the reported crash came from expanding the *inspector* on the right, which is a
    /// different split view entirely.
    private static func dragAllDividers(in window: NSWindow, expanding: Bool) async {
        for split in splitViews(in: window.contentView) {
            let count = split.arrangedSubviews.count
            guard count > 1 else { continue }
            for dividerIndex in 0..<(count - 1) {
                await drag(split: split, dividerIndex: dividerIndex, in: window, expanding: expanding)
            }
        }
    }

    private static func drag(split: NSSplitView, dividerIndex: Int, in window: NSWindow, expanding: Bool) async {
        let arranged = split.arrangedSubviews
        guard dividerIndex < arranged.count - 1 else { return }
        let vertical = !split.isVertical ? false : true
        let edge = vertical ? arranged[dividerIndex].frame.maxX : arranged[dividerIndex].frame.maxY
        let centre = vertical
            ? NSPoint(x: edge + split.dividerThickness / 2, y: split.frame.midY)
            : NSPoint(x: split.frame.midX, y: edge + split.dividerThickness / 2)
        let inWindow = split.convert(centre, to: nil)

        func event(_ type: NSEvent.EventType, at location: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }

        // Push well past the pane's limits in both directions: the interesting failures
        // happen when a pane is driven to (or past) its minimum or maximum width.
        let travel: Double = expanding ? -260 : 260
        guard let down = event(.leftMouseDown, at: inWindow) else { return }
        // Queue the drag and release first: `mouseDown:` blocks in its own loop until
        // it sees them.
        for step in stride(from: 20.0, through: abs(travel), by: 20.0) {
            let delta = travel < 0 ? -step : step
            let point = vertical
                ? NSPoint(x: inWindow.x + delta, y: inWindow.y)
                : NSPoint(x: inWindow.x, y: inWindow.y + delta)
            if let drag = event(.leftMouseDragged, at: point) { window.postEvent(drag, atStart: false) }
        }
        let end = vertical
            ? NSPoint(x: inWindow.x + travel, y: inWindow.y)
            : NSPoint(x: inWindow.x, y: inWindow.y + travel)
        if let up = event(.leftMouseUp, at: end) { window.postEvent(up, atStart: false) }
        split.mouseDown(with: down)
        try? await Task.sleep(for: .milliseconds(50))
    }

    private static func splitViews(in view: NSView?) -> [NSSplitView] {
        guard let view else { return [] }
        var found: [NSSplitView] = []
        if let split = view as? NSSplitView { found.append(split) }
        for child in view.subviews { found.append(contentsOf: splitViews(in: child)) }
        return found
    }

    private static func log(_ message: String) { print("STRESS: \(message)") }
}
