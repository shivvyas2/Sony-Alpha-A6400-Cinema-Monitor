import Foundation
import Network

public struct BridgeHost: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let endpoint: NWEndpoint
    public static func == (a: BridgeHost, b: BridgeHost) -> Bool { a.name == b.name }
}

/// Finds Macs running the CinemaHUD bridge via Bonjour and resolves them to an HTTP base URL.
public final class BridgeDiscovery: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "cinemahud.bridge.discovery")
    public init() {}

    public func hosts() -> AsyncStream<[BridgeHost]> {
        AsyncStream { cont in
            let b = NWBrowser(for: .bonjour(type: Bridge.serviceType, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { results, _ in
                let hosts = results.compactMap { r -> BridgeHost? in
                    if case .service(let name, _, _, _) = r.endpoint { return BridgeHost(name: name, endpoint: r.endpoint) }
                    return nil
                }
                cont.yield(hosts.sorted { $0.name < $1.name })
            }
            b.stateUpdateHandler = { st in if case .failed = st { cont.finish() } }
            b.start(queue: queue)
            browser = b
            cont.onTermination = { _ in b.cancel() }
        }
    }

    /// Opens a connection to the Bonjour endpoint just long enough to learn its host and port.
    public static func resolve(_ host: BridgeHost) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let conn = NWConnection(to: host.endpoint, using: .tcp)
            var done = false
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    guard !done else { return }; done = true
                    if case .hostPort(let h, let p)? = conn.currentPath?.remoteEndpoint {
                        var hs = "\(h)"
                        if let i = hs.firstIndex(of: "%") { hs = String(hs[..<i]) }   // strip interface scope
                        if hs.contains(":") { hs = "[\(hs)]" }
                        cont.resume(returning: URL(string: "http://\(hs):\(p.rawValue)")!)
                    } else { cont.resume(throwing: UnsupportedOperation("Could not resolve \(host.name)")) }
                    conn.cancel()
                case .failed(let e):
                    guard !done else { return }; done = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            conn.start(queue: DispatchQueue(label: "cinemahud.bridge.resolve"))
        }
    }
}
