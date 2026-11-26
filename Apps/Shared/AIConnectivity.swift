import Combine
import Foundation
import Network

@MainActor
final class AIConnectivity: ObservableObject {
    static let shared = AIConnectivity()
    @Published private(set) var offline: Bool?
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status == .unsatisfied
            Task { @MainActor in self?.offline = offline }
        }
        monitor.start(queue: DispatchQueue(label: "CloudReader.AIConnectivity"))
    }

    func offlineForRequest() async -> Bool {
        if let offline { return offline }
        for await value in $offline.values {
            if let value { return value }
        }
        return false
    }
}
