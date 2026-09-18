import Foundation
import UIKit
import os

/// Adaptive low-memory policy for MeloNext on iOS/iPadOS.
///
/// iOS exposes the amount of memory still available to the current process.
/// We use that signal to tell cache owners when to purge rather than trying
/// to allocate up to a guessed device limit.
public final class MeloNextMemoryManager {
    public enum Profile: String, CaseIterable, Identifiable {
        case automatic
        case eightGB = "8GB"
        case twelveGB = "12GB"

        public var id: String { rawValue }
    }

    public struct Policy: Equatable {
        public let cacheBudgetMB: Int
        public let shaderCacheBudgetMB: Int
        public let aggressiveCleanup: Bool

        public static let automatic = Policy(
            cacheBudgetMB: 384,
            shaderCacheBudgetMB: 128,
            aggressiveCleanup: true
        )

        public static let eightGB = Policy(
            cacheBudgetMB: 320,
            shaderCacheBudgetMB: 96,
            aggressiveCleanup: true
        )

        public static let twelveGB = Policy(
            cacheBudgetMB: 512,
            shaderCacheBudgetMB: 192,
            aggressiveCleanup: true
        )
    }

    public static let shared = MeloNextMemoryManager()

    public private(set) var profile: Profile = .automatic
    public private(set) var currentPolicy: Policy = .automatic
    public private(set) var availableMemoryBytes: UInt64 = 0

    private var monitorTimer: Timer?

    private init() {
        apply(profile: .automatic)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        monitorTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [weak self] _ in
            self?.sampleAvailableMemory()
        }

        sampleAvailableMemory()
    }

    deinit {
        monitorTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    public var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    /// Advisory bytes remaining before the current app memory limit.
    public func sampleAvailableMemory() -> UInt64 {
        let value = UInt64(os_proc_available_memory())
        availableMemoryBytes = value

        if value > 0 && value < 512 * 1024 * 1024 {
            handleMemoryPressure(.warning)
        }

        return value
    }

    public func apply(profile: Profile) {
        self.profile = profile
        self.currentPolicy = policy(for: profile)
        sampleAvailableMemory()
    }

    public func policy(for profile: Profile) -> Policy {
        switch profile {
        case .automatic:
            return physicalMemoryGB <= 8 ? .eightGB : .twelveGB
        case .eightGB:
            return .eightGB
        case .twelveGB:
            return .twelveGB
        }
    }

    @discardableResult
    public func handleMemoryPressure(_ level: MemoryPressureLevel) -> Bool {
        switch level {
        case .normal:
            return false
        case .warning:
            NotificationCenter.default.post(
                name: .meloNextPurgeTransientCaches,
                object: nil
            )
            return true
        case .critical:
            NotificationCenter.default.post(
                name: .meloNextPurgeAllCaches,
                object: nil
            )
            return true
        }
    }

    @objc private func handleMemoryWarning() {
        availableMemoryBytes = 0
        _ = handleMemoryPressure(.critical)
        NotificationCenter.default.post(
            name: .meloNextMemoryPressure,
            object: MemoryPressureLevel.critical
        )
    }

    public enum MemoryPressureLevel {
        case normal
        case warning
        case critical
    }
}

public extension Notification.Name {
    static let meloNextMemoryPressure = Notification.Name("MeloNextMemoryPressure")
    static let meloNextPurgeTransientCaches = Notification.Name("MeloNextPurgeTransientCaches")
    static let meloNextPurgeAllCaches = Notification.Name("MeloNextPurgeAllCaches")
}
