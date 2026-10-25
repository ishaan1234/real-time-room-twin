import Foundation

/// Debug-build diagnostics for tracking down UI freezes. Everything here
/// compiles to nothing in Release.
enum Diagnostics {
    #if DEBUG
    private static let lock = NSLock()
    private static var activity = "launch"
    private static var lastAction = "none"
    private static var lastMainResponse = Date()
    private static var lastTick = Date()
    private static var stallReported = false
    private static var timer: DispatchSourceTimer?
    #endif

    /// Records what the main thread is doing, e.g. "draw: waiting for GPU".
    static func note(_ what: String) {
        #if DEBUG
        lock.lock(); activity = what; lock.unlock()
        #endif
    }

    /// Records a user action and prints it.
    static func action(_ what: String) {
        #if DEBUG
        lock.lock(); lastAction = what; lock.unlock()
        log("action: \(what)")
        #endif
    }

    static func log(_ message: String) {
        #if DEBUG
        print("[RoomTwin \(String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] \(message)")
        #endif
    }

    /// Pings the main thread 4 times a second and reports any stall over 1 s,
    /// with the main thread's last noted activity and the last user action.
    /// If the watchdog's own ticks stop too, the whole app was suspended
    /// (background, lock screen), and that is reported separately.
    static func startWatchdog() {
        #if DEBUG
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 0.25)
        timer.setEventHandler {
            let now = Date()
            lock.lock()
            let tickGap = now.timeIntervalSince(lastTick)
            let suspended = tickGap > 1
            lastTick = now
            if suspended { lastMainResponse = now }
            let report = !suspended && now.timeIntervalSince(lastMainResponse) > 1 && !stallReported
            if report { stallReported = true }
            let (doing, after) = (activity, lastAction)
            lock.unlock()
            if suspended {
                log(String(format: "app was suspended for %.1f s", tickGap))
            }
            if report {
                log("MAIN THREAD BLOCKED for >1 s; doing: \(doing); last action: \(after)")
            }
            DispatchQueue.main.async {
                let now = Date()
                lock.lock()
                let blocked = now.timeIntervalSince(lastMainResponse)
                // This block can run before the first tick after a suspension.
                let suspended = now.timeIntervalSince(lastTick) > 1
                lastMainResponse = now
                stallReported = false
                lock.unlock()
                if blocked > 1 && !suspended {
                    log(String(format: "main thread responsive again after %.1f s", blocked))
                }
            }
        }
        timer.resume()
        self.timer = timer
        #endif
    }
}
