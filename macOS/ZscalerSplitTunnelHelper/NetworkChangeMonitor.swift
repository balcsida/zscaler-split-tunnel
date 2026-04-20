import Foundation
import SystemConfiguration
import os

/// Event-driven replacement for polling the default gateway every cycle.
///
/// Subscribes to SCDynamicStore notifications on the global IPv4/IPv6/DNS state
/// keys so the helper reacts to DHCP/interface transitions within hundreds of
/// milliseconds instead of waiting up to `MonitorLoop.interval` seconds for the
/// next tick. The existing `runCycle` signature check is kept as a belt-and-
/// suspenders safety net in case SCDynamicStore ever misses an event.
///
/// Notifications arrive in rapid bursts during a network change (primary
/// service swap, v4 update, v6 update, DNS update), so callbacks are coalesced
/// through a short debounce window. The wrapped `onChange` fires once per
/// transition, on `queue`.
final class NetworkChangeMonitor: @unchecked Sendable {
    private static let debounceInterval: TimeInterval = 0.5

    private let logger = Logger(subsystem: AppConstants.helperBundleID, category: "NetworkChangeMonitor")
    private let queue = DispatchQueue(label: "com.zscaler-split-tunnel.helper.netmon", qos: .utility)
    private var store: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    private var pendingFire: DispatchWorkItem?
    private var onChange: (@Sendable () -> Void)?

    func start(onChange: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self, self.store == nil else { return }
            self.onChange = onChange
            self.install()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingFire?.cancel()
            self.pendingFire = nil
            if let source = self.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            }
            self.runLoopSource = nil
            self.store = nil
            self.onChange = nil
            self.logger.info("Stopped SCDynamicStore network change monitoring")
        }
    }

    // MARK: - Private

    private func install() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<NetworkChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.scheduleFire()
        }

        guard let store = SCDynamicStoreCreate(
            nil,
            "com.zscaler-split-tunnel.helper.netmon" as CFString,
            callback,
            &context
        ) else {
            logger.error("SCDynamicStoreCreate failed — falling back to polling only")
            return
        }

        // These three global keys flip whenever the primary network changes:
        //   - Global/IPv4: primary v4 service / default gateway swapped
        //   - Global/IPv6: primary v6 service / default gateway swapped
        //   - Global/DNS:  resolver list changed (office/home handoff signal)
        let keys: [CFString] = [
            "State:/Network/Global/IPv4" as CFString,
            "State:/Network/Global/IPv6" as CFString,
            "State:/Network/Global/DNS" as CFString,
        ]

        guard SCDynamicStoreSetNotificationKeys(store, keys as CFArray, nil) else {
            logger.error("SCDynamicStoreSetNotificationKeys failed — falling back to polling only")
            return
        }

        guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            logger.error("SCDynamicStoreCreateRunLoopSource failed — falling back to polling only")
            return
        }

        // Attach to the main runloop that `main.swift` already spins. The
        // callback does nothing but hop onto `queue` and schedule debounced
        // work, so the main thread is never blocked.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.store = store
        self.runLoopSource = source
        logger.info("Started SCDynamicStore network change monitoring")
    }

    private func scheduleFire() {
        queue.async { [weak self] in
            guard let self, self.store != nil else { return }
            self.pendingFire?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let handler = self.onChange else { return }
                self.logger.info("Network change event fired")
                handler()
            }
            self.pendingFire = work
            self.queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
        }
    }
}
