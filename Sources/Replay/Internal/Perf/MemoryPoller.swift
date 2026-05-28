import Foundation
import Darwin

/// Polls process resident memory every 30s and emits `memory_rss_mb`.
///
/// Uses Mach's `task_info(MACH_TASK_BASIC_INFO, ...)` — the canonical
/// way to get a process's resident set size on Darwin. Apple docs +
/// every Activity Monitor clone use this. Apple's TN2434 walks
/// through it.
///
/// Apple introduced `phys_footprint` in iOS 13 which is more
/// accurate (includes IOKit + GPU memory) but harder to read
/// cleanly; resident_size covers the common case for analytics.
///
/// Reads + emits on a background `DispatchSourceTimer` so we don't
/// touch the main thread.
final class MemoryPoller {

    private let emit: (_ metric: String, _ value: Double, _ unit: String, _ rating: String?) -> Void
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.replayfy.ios.memory", qos: .utility)

    /// Poll interval matches the matrix doc — 30s. Background poll
    /// frequencies above this start showing up in Energy Impact
    /// reports.
    private let intervalSec: TimeInterval = 30

    init(emit: @escaping (String, Double, String, String?) -> Void) {
        self.emit = emit
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + intervalSec, repeating: intervalSec)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Returns resident memory in MiB, or nil on failure. Public for
    /// tests + cold-start emission.
    func currentMemoryMb() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // resident_size is bytes — convert to MiB (1024 * 1024).
        return Double(info.resident_size) / (1024 * 1024)
    }

    private func poll() {
        guard let mb = currentMemoryMb() else { return }
        emit("memory_rss_mb", mb, "mb", rating(for: mb))
    }

    /// Thresholds from mobile-vitals-matrix.md.
    private func rating(for mb: Double) -> String {
        if mb < 150 { return "good" }
        if mb < 300 { return "needs-improvement" }
        return "poor"
    }
}
