import Network
import Observation

/// Monitors network connectivity using NWPathMonitor.
@MainActor
@Observable
final class NetworkMonitor {
    /// Whether the device currently has a usable network connection.
    private(set) var isConnected: Bool = true
    /// Cellular or metered Wi-Fi / personal hotspot; safe default before first path update.
    private(set) var isCellularOrExpensive: Bool = true

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
                self?.isCellularOrExpensive = path.usesInterfaceType(.cellular) || path.isExpensive
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    deinit {
        monitor.cancel()
    }
}
