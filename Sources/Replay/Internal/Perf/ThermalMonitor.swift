import Foundation

/// Observes `ProcessInfo.thermalState` and emits `thermal_state`
/// when it changes.
///
/// Apple's thermal scale: nominal (0) → fair (1) → serious (2) →
/// critical (3). Higher is worse — same direction as the matrix
/// doc, so MAX is the right aggregation server-side.
///
/// On-change emission rather than periodic polling because the OS
/// posts ``ProcessInfo.thermalStateDidChangeNotification`` when
/// state crosses thresholds — no extra timer needed.
final class ThermalMonitor {

    private let emit: (_ metric: String, _ value: Double, _ unit: String, _ rating: String?) -> Void
    private var observer: NSObjectProtocol?
    /// Most-recent emitted value — used to suppress duplicate emits
    /// when the OS fires the notification but the level didn't
    /// actually move (rare but documented).
    private var lastEmitted: ProcessInfo.ThermalState?

    init(emit: @escaping (String, Double, String, String?) -> Void) {
        self.emit = emit
    }

    func start() {
        // Emit an initial reading so the session always has a baseline
        // thermal_state — even sessions that never cross a threshold
        // get the nominal value on record.
        emitCurrent()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.emitCurrent() }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        lastEmitted = nil
    }

    private func emitCurrent() {
        let state = ProcessInfo.processInfo.thermalState
        if state == lastEmitted { return }
        lastEmitted = state
        let value = Double(numericValue(state))
        emit("thermal_state", value, "", rating(for: state))
    }

    /// Map ProcessInfo.ThermalState to the cross-platform 0-3 scale
    /// from the matrix doc. ProcessInfo's raw values happen to match
    /// (nominal=0, fair=1, serious=2, critical=3) so this is mostly
    /// future-proofing against Apple adding a new tier.
    private func numericValue(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 3
        }
    }

    private func rating(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "good"
        case .fair: return "needs-improvement"
        case .serious, .critical: return "poor"
        @unknown default: return "poor"
        }
    }
}
