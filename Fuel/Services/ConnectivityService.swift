import Foundation
import Network

protocol ConnectivityMonitoring: Sendable {
    func updates() -> AsyncStream<Bool>
}

struct LiveConnectivityMonitor: ConnectivityMonitoring {
    func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.pak.fuel.connectivity", qos: .utility)
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }
}
