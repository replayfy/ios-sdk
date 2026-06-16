#if canImport(UIKit)
import UIKit

// MARK: - Screen tracking

/// Swizzles `UIViewController.viewDidAppear/Disappear` and reports a
/// screen (viewComponent) message with the controller's class name —
/// drives the dashboard's Screens tab + route labels.
enum MobileScreenTracker {
    private static var installed = false
    private static var handler: ((_ screen: String, _ visible: Bool) -> Void)?

    static func install(_ handler: @escaping (_ screen: String, _ visible: Bool) -> Void) {
        self.handler = handler
        guard !installed else { return }
        installed = true
        swizzle(#selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.replay_mobileViewDidAppear(_:)))
        swizzle(#selector(UIViewController.viewDidDisappear(_:)), #selector(UIViewController.replay_mobileViewDidDisappear(_:)))
    }

    static func report(_ vc: UIViewController, visible: Bool) {
        handler?(String(describing: type(of: vc)), visible)
    }

    private static func swizzle(_ original: Selector, _ swizzled: Selector) {
        guard let o = class_getInstanceMethod(UIViewController.self, original),
              let s = class_getInstanceMethod(UIViewController.self, swizzled) else { return }
        method_exchangeImplementations(o, s)
    }
}

extension UIViewController {
    // Distinct selector names from the legacy ScreenAutoDetector swizzle
    // (which also trampolines through viewDidAppear). The two chain
    // cleanly: viewDidAppear → this → the legacy hop → the original.
    @objc fileprivate func replay_mobileViewDidAppear(_ animated: Bool) {
        self.replay_mobileViewDidAppear(animated)
        MobileScreenTracker.report(self, visible: true)
    }
    @objc fileprivate func replay_mobileViewDidDisappear(_ animated: Bool) {
        self.replay_mobileViewDidDisappear(animated)
        MobileScreenTracker.report(self, visible: false)
    }
}

// MARK: - Performance

/// CPU (5 s) + memory (10 s) sampling, plus on-change thermal / battery
/// / low-power / orientation notifications. Each emits a
/// performanceEvent {name, value}, matching the reference metrics.
final class MobilePerfMonitor {
    private let emit: (_ name: String, _ value: UInt64) -> Void
    private var cpuTimer: Timer?
    private var memTimer: Timer?
    private var batteryTimer: Timer?

    init(emit: @escaping (_ name: String, _ value: UInt64) -> Void) { self.emit = emit }

    func start() {
        DispatchQueue.main.async {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(self.onNotify(_:)), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.onNotify(_:)), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.onNotify(_:)), name: UIDevice.batteryStateDidChangeNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.onNotify(_:)), name: .NSProcessInfoPowerStateDidChange, object: nil)
            nc.addObserver(self, selector: #selector(self.onNotify(_:)), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.onNotify(_:)), name: .NSBundleResourceRequestLowDiskSpace, object: nil)
            self.sampleCPU(); self.sampleMemory(); self.sampleBattery()
            self.cpuTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sampleCPU() }
            self.memTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.sampleMemory() }
            // Battery changes slowly — a 30s poll is plenty and guarantees a
            // drain curve even when the OS fires no level-change notification
            // during the session (common on short sessions / real devices).
            self.batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.sampleBattery() }
        }
    }

    func stop() {
        cpuTimer?.invalidate(); cpuTimer = nil
        memTimer?.invalidate(); memTimer = nil
        batteryTimer?.invalidate(); batteryTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// Emit the current battery level + state. Skips when the level is < 0 —
    /// the Simulator (and devices with monitoring unavailable) report -1, and
    /// emitting a phantom 0% would read as a dead/draining battery downstream.
    private func sampleBattery() {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return }
        emit("batteryLevel", UInt64(level * 100))
        emit("batteryState", UInt64(UIDevice.current.batteryState.rawValue))
    }

    @objc private func onNotify(_ n: Notification) {
        switch n.name {
        case ProcessInfo.thermalStateDidChangeNotification:
            emit("thermalState", UInt64(ProcessInfo.processInfo.thermalState.rawValue))
        case UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification:
            sampleBattery()
        case .NSProcessInfoPowerStateDidChange:
            emit("isLowPowerModeEnabled", ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0)
        case UIApplication.didReceiveMemoryWarningNotification:
            emit("memoryWarning", 0)
        case .NSBundleResourceRequestLowDiskSpace:
            emit("lowDiskSpace", 0)
        default: break
        }
    }

    private func sampleMemory() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS { emit("memoryUsage", UInt64(info.phys_footprint)) }
    }

    private func sampleCPU() {
        var list: thread_act_array_t?
        var n = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let list = list, n > 0 else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(n) * MemoryLayout<thread_t>.stride)) }
        var info = thread_basic_info()
        var ic = mach_msg_type_number_t(THREAD_INFO_MAX)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                thread_info(list[0], thread_flavor_t(THREAD_BASIC_INFO), $0, &ic)
            }
        }
        if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
            emit("mainThreadCPU", UInt64(Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100))
        }
    }
}

// MARK: - Crash

/// Installs an uncaught-exception handler that flushes a crash message
/// before the app dies. (Signal handling is a follow-up.)
enum MobileCrashHandler {
    private static var emit: ((_ name: String, _ reason: String, _ stack: String) -> Void)?

    static func install(_ emit: @escaping (_ name: String, _ reason: String, _ stack: String) -> Void) {
        self.emit = emit
        NSSetUncaughtExceptionHandler { exception in
            MobileCrashHandler.emit?(
                exception.name.rawValue,
                exception.reason ?? "",
                exception.callStackSymbols.joined(separator: "\n")
            )
        }
    }
}
#endif
