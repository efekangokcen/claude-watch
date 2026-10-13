import Foundation
import Network
import Observation

/// Finds bridges on the local network via Bonjour (_claude-watch._tcp) and resolves them to host:port.
@MainActor
@Observable
final class BridgeDiscovery {
    struct Found: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var hostPort: String?   // nil until resolved
    }

    private(set) var found: [Found] = []
    private(set) var isBrowsing = false
    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_claude-watch._tcp", domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.isBrowsing = (state == .ready)
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handle(results)
            }
        }
        b.start(queue: .main)
        browser = b
        isBrowsing = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for (_, c) in resolvers { c.cancel() }
        resolvers.removeAll()
        isBrowsing = false
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var next: [Found] = []
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            let existing = found.first { $0.name == name }
            next.append(Found(name: name, hostPort: existing?.hostPort))
            if existing?.hostPort == nil, resolvers[name] == nil {
                resolve(name: name, endpoint: r.endpoint)
            }
        }
        found = next.sorted { $0.name < $1.name }
    }

    /// Open a throwaway TCP connection to the service endpoint; once ready, read the concrete IP:port.
    private func resolve(name: String, endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        resolvers[name] = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = conn.currentPath?.remoteEndpoint {
                        let h: String
                        switch host {
                        case .ipv4(let a): h = "\(a)"
                        case .ipv6(let a): h = "[\(a)]"
                        case .name(let n, _): h = n
                        @unknown default: h = "\(host)"
                        }
                        let clean = h.split(separator: "%").first.map(String.init) ?? h
                        if let i = self.found.firstIndex(where: { $0.name == name }) {
                            self.found[i].hostPort = "\(clean):\(port.rawValue)"
                        }
                    }
                    conn.cancel()
                    self.resolvers[name] = nil
                case .failed, .cancelled:
                    self.resolvers[name] = nil
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }
}
