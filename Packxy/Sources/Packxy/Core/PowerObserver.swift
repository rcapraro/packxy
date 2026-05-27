// macOS sleep / wake notifications surfaced as a Swift AsyncStream.
//
// NSWorkspace's notification center delivers sleep/wake events on the
// main thread, with sub-second precision, and without any of the
// IOKit C plumbing the Go code went through. ConnectionManager
// consumes the stream in a long-lived Task and reacts:
//
//   .willSleep → SIGTERM openfortivpn so the FortiGate session is
//                released cleanly (otherwise the gateway holds it
//                until LCP echo timeout — ~60s after wake).
//   .didWake   → mark the next drop as `.wake` so the redemand
//                dialog uses the wake-flavoured Reason.

import AppKit
import Foundation

enum PowerEvent: Sendable {
    case willSleep
    case didWake
}

enum PowerObserver {
    /// Returns an async stream of sleep/wake events. The stream stays
    /// alive until the consumer cancels it (Task.cancel) or drops the
    /// iterator. Observers are removed automatically on termination.
    static func events() -> AsyncStream<PowerEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let sleepObs = center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil, queue: .main
            ) { _ in
                continuation.yield(.willSleep)
            }
            let wakeObs = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main
            ) { _ in
                continuation.yield(.didWake)
            }
            continuation.onTermination = { _ in
                center.removeObserver(sleepObs)
                center.removeObserver(wakeObs)
            }
        }
    }
}
