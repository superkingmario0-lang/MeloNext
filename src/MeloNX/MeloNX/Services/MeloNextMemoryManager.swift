import Foundation
import UIKit

/// Adaptive memory policy for MeloNext on iOS/iPadOS.
///
/// The profiles are targets for cache and workload tuning; they are not hard
/// allocations or guarantees about how much memory iOS will permit the app to use.
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
            cacheBudgetMB: 768,
            shaderCacheBudgetMB: 384,
            aggressiveCleanup: false
        )

        public static let eightGB = Policy(
            cacheBudgetMB: 512,
            shaderCacheBudgetMB: 256,
            aggressiveCleanup: true
        )

        public static let twelveGB = Policy(
            cacheBudgetMB: 1024,
            shaderCacheBudgetMB: 512,
            aggressiveCleanup: false
        )
    }

    public static let shared = MeloNextMemoryManager()

    public private(set) var profile: Profile = .automatic
    public private(set) var currentPolicy: Policy = .automatic

    private init() {
        apply(profile: .automatic)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func apply(profile: Profile) {
        self.profile = profile
        self.currentPolicy = policy(for: profile)
    }

    public func policy(for profile: Profile) -> Policy {
        switch profile {
        case .automatic:
            // Prefer a conservative policy. iOS memory limits vary by device
            // and OS version, so hardware RAM is not treated as an app quota.
            return .automatic
        case .eightGB:
            return .eightGB
        case .twelveGB:
            return .twelveGB
        }
    }

    /// Call from cache owners when memory pressure changes.
    /// Returns true when caches should be purged immediately.
    @discardableResult
    public func handleMemoryPressure(_ level: MemoryPressureLevel) -> Bool {
        switch level {
        case .normal:
            return false
        case .warning:
            return true
        case .critical:
            return true
        }
    }

    @objc private func handleMemoryWarning() {
        // Individual cache systems should observe this manager and purge their
        // transient allocations. We deliberately do not force an unsafe global
        // allocation/deallocation cycle here.
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
}
