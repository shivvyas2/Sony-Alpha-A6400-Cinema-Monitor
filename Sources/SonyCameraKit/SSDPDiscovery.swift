import Foundation
import Darwin

public struct DiscoveredCamera: Sendable, Equatable, Identifiable {
    public var id: String { serviceURL.absoluteString }
    public let friendlyName: String
    public let modelName: String
    public let serviceURL: URL     // http://host:port/sony
    public let liveviewURL: URL?   // may be absent in the description
    public init(friendlyName: String, modelName: String, serviceURL: URL, liveviewURL: URL? = nil) {
        self.friendlyName = friendlyName; self.modelName = modelName; self.serviceURL = serviceURL; self.liveviewURL = liveviewURL
    }
}

/// Finds Sony cameras via SSDP (`urn:schemas-sony-com:service:ScalarWebAPI:1`).
public enum SSDPDiscovery {
    public static let searchTarget = "urn:schemas-sony-com:service:ScalarWebAPI:1"
    public static let defaultServiceURL = URL(string: "http://192.168.122.1:8080/sony")!

    /// Broadcasts an M-SEARCH and collects device-description LOCATION URLs for `timeout` seconds.
    public static func searchLocations(timeout: TimeInterval = 3) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) { () -> [URL] in
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var ttl: UInt8 = 2
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(1900).bigEndian
            addr.sin_addr.s_addr = inet_addr("239.255.255.250")

            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(searchTarget)\r\n\r\n"
            let bytes = Array(msg.utf8)
            for _ in 0 ..< 2 {
                let sent = withUnsafePointer(to: &addr) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if sent < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            }

            var locations: [URL] = []
            let deadline = Date().addingTimeInterval(timeout)
            var buf = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                let text = String(decoding: buf[0 ..< n], as: UTF8.self)
                for line in text.components(separatedBy: "\r\n") {
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, parts[0].uppercased() == "LOCATION", let u = URL(string: parts[1]), !locations.contains(u) {
                        locations.append(u)
                    }
                }
            }
            return locations
        }.value
    }

    /// Downloads and parses a device description XML.
    public static func describe(location: URL) async throws -> DiscoveredCamera {
        var req = URLRequest(url: location); req.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: req)
        return try parseDescription(data, base: location)
    }

    public static func parseDescription(_ data: Data, base: URL) throws -> DiscoveredCamera {
        let xml = String(decoding: data, as: UTF8.self)
        func tag(_ name: String) -> String? {
            guard let r = xml.range(of: "<\(name)>"), let e = xml.range(of: "</\(name)>", range: r.upperBound ..< xml.endIndex) else { return nil }
            return String(xml[r.upperBound ..< e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // <av:X_ScalarWebAPI_Service><av:X_ScalarWebAPI_ServiceType>camera</...><av:X_ScalarWebAPI_ActionList_URL>http://...:8080/sony</...>
        var serviceURL: URL?
        var search = xml.startIndex
        while let r = xml.range(of: "X_ScalarWebAPI_ServiceType>", range: search ..< xml.endIndex) {
            guard let close = xml.range(of: "<", range: r.upperBound ..< xml.endIndex) else { break }
            let type = xml[r.upperBound ..< close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if type == "camera", let u = xml.range(of: "X_ScalarWebAPI_ActionList_URL>", range: close.upperBound ..< xml.endIndex),
               let uc = xml.range(of: "<", range: u.upperBound ..< xml.endIndex) {
                serviceURL = URL(string: xml[u.upperBound ..< uc.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }
            search = close.upperBound
        }
        guard let serviceURL else { throw SonyAPIError(code: -2, message: "no camera service in device description", method: "describe") }
        let lv = tag("av:X_ScalarWebAPI_LiveView_URL").flatMap(URL.init(string:))
        return DiscoveredCamera(friendlyName: tag("friendlyName") ?? "Sony Camera",
                                modelName: tag("modelName") ?? "",
                                serviceURL: serviceURL, liveviewURL: lv)
    }

    /// SSDP search, then fall back to probing the well-known direct-Wi-Fi address.
    public static func discover(timeout: TimeInterval = 3) async -> [DiscoveredCamera] {
        var found: [DiscoveredCamera] = []
        if let locations = try? await searchLocations(timeout: timeout) {
            for loc in locations {
                if let cam = try? await describe(location: loc), !found.contains(cam) { found.append(cam) }
            }
        }
        if found.isEmpty {
            let client = SonyCameraClient(serviceURL: defaultServiceURL)
            if (try? await client.call("getAvailableApiList", timeout: 3)) != nil {
                found.append(DiscoveredCamera(friendlyName: "Sony Camera", modelName: "", serviceURL: defaultServiceURL))
            }
        }
        return found
    }
}
