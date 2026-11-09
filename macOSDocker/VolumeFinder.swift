import AppKit
import NetFS
import CryptoKit
import dnssd

@MainActor
final class VolumeFinder {
    private let password = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var mounts: [String: URL] = [:]
    private var opening = false
    private var stopped = false

    func mount(name: String, control: SocketHTTP, port: UInt16, bridgeAddress: String? = nil, serviceHost: String? = nil) async throws -> URL {
        guard !opening, !stopped else { throw AppFailure(message: String(localized: "Volume-Zugriff ist bereits beschäftigt oder beendet.")) }
        opening = true
        defer { opening = false }
        let health = try JSONSerialization.jsonObject(with: await control.request("GET", "/health")) as? [String: Any]
        guard health?["volumeSMBVersion"] as? Int == 1 else {
            throw AppFailure(message: String(localized: "Für Finder-Zugriff bitte die VM stoppen und unter Runtime das enthaltene Basisimage aktualisieren. Die Docker-Daten bleiben erhalten."))
        }
        let directSMB = bridgeAddress != nil && health?["volumeSMBLANVersion"] as? Int == 2
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "password": password, "lan": directSMB] as [String: Any])
        let response = try await control.request("POST", "/volume-smb", body: body)
        let export = try JSONSerialization.jsonObject(with: response) as? [String: String]
        let legacyShare = "v" + SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let visibleShare = ["global", "homes", "printers"].contains(name.lowercased()) ? name + ".volume" : name
        guard let share = export?["share"], share == visibleShare || share == legacyShare else {
            throw AppFailure(message: String(localized: "Ungültige Volume-Adresse."))
        }
        if let existing = mounts[name], Self.isMounted(existing) { return existing }
        var components = URLComponents()
        components.scheme = "smb"
        if directSMB, let bridgeAddress {
            let namedAddress = await Task.detached {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo("macosdocker.local", nil, &hints, &result) == 0, let first = result else { return false }
                defer { freeaddrinfo(first) }
                var matched = false
                var current: UnsafeMutablePointer<addrinfo>? = first
                while let entry = current {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                          String(cString: buffer) == bridgeAddress else { return false }
                    matched = true
                    current = entry.pointee.ai_next
                }
                return matched
            }.value
            components.host = namedAddress ? (serviceHost ?? "macosdocker.local") : bridgeAddress
            components.port = namedAddress && serviceHost != nil ? nil : 445
        } else {
            components.host = "127.0.0.1"
            components.port = Int(port)
        }
        components.path = "/" + share
        guard let url = components.url else { throw AppFailure(message: String(localized: "Ungültige Volume-Adresse.")) }
        let requestedDirectory = RuntimeManager.socketDirectory.appendingPathComponent("volumes", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: requestedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let resolved = requestedDirectory.path.withCString({ realpath($0, nil) }) else {
            throw AppFailure(message: String(localized: "Ungültige Volume-Adresse."))
        }
        let mountDirectory = URL(fileURLWithPath: String(cString: resolved))
        free(resolved)
        let secret = password
        let mounted: URL = try await Task.detached {
            var points: Unmanaged<CFArray>?
            let options = NSMutableDictionary(dictionary: ["AllowLoopback": true, "ForceNewSession": true, "UIOption": "NoUI"])
            let result = NetFSMountURLSync(url as CFURL, mountDirectory as CFURL, "volumeaccess" as CFString, secret as CFString, options, NSMutableDictionary(dictionary: ["MountAtMountDir": true]), &points)
            let paths = points?.takeRetainedValue() as? [String]
            guard result == 0, let path = paths?.first else {
                throw AppFailure(message: String(localized: "SMB-Volume konnte nicht verbunden werden (Fehler \(result))."))
            }
            return URL(fileURLWithPath: path)
        }.value
        guard !stopped else {
            Self.unmount(mounted)
            throw CancellationError()
        }
        mounts[name] = mounted
        return mounted
    }

    func disconnect(only volume: String? = nil) async throws {
        guard !opening else { throw AppFailure(message: String(localized: "Volume-Zugriff ist bereits beschäftigt oder beendet.")) }
        opening = true
        defer { opening = false }
        let selected = mounts.filter { volume == nil || $0.key == volume }
        var failed = false
        await withTaskGroup(of: (String, URL, Bool).self) { group in
            for (name, url) in selected {
                group.addTask { (name, url, await Self.disconnectMount(url)) }
            }
            for await (name, url, disconnected) in group {
                if disconnected {
                    if mounts[name] == url { mounts.removeValue(forKey: name) }
                } else {
                    failed = true
                }
            }
        }
        if failed {
            throw AppFailure(message: String(localized: "Bitte geöffnete Dateien im Volume schließen und erneut stoppen."))
        }
    }

    func stop() {
        stopped = true
        for url in mounts.values { Self.unmount(url) }
        mounts.removeAll()
    }

    nonisolated private static func isMounted(_ url: URL) -> Bool {
        var status = statfs()
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard fstatfs(fd, &status) == 0 else { return false }
        let type = withUnsafeBytes(of: &status.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return type == "smbfs"
    }

    nonisolated private static func disconnectMount(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let disconnected = !isMounted(url) || url.path.withCString { Darwin.unmount($0, 0) } == 0 || !isMounted(url)
                if disconnected { removeEmptyMountDirectory(url) }
                continuation.resume(returning: disconnected)
            }
        }
    }

    nonisolated private static func removeEmptyMountDirectory(_ url: URL) {
        _ = url.path.withCString { Darwin.rmdir($0) }
        _ = url.deletingLastPathComponent().path.withCString { Darwin.rmdir($0) }
    }

    private static func unmount(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            if url.path.withCString({ Darwin.unmount($0, 0) }) == 0 {
                removeEmptyMountDirectory(url)
            }
        }
    }
}

@MainActor
final class VMHostname {
    private var service: DNSServiceRef?
    private var address: String?
    private var smbService: DNSServiceRef?
    private(set) var serviceHost: String?

    func update(address: String?, interface: String) {
        guard self.address != address else { return }
        stop()
        guard let address, if_nametoindex(interface) != 0 else { return }
        var value = in_addr()
        guard inet_pton(AF_INET, address, &value) == 1 else { return }
        var connection: DNSServiceRef?
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError, let connection else { return }
        var record: DNSRecordRef?
        let result = withUnsafePointer(to: &value) {
            DNSServiceRegisterRecord(connection, &record, DNSServiceFlags(kDNSServiceFlagsUnique), if_nametoindex(interface), "macosdocker.local.", UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), UInt16(MemoryLayout<in_addr>.size), $0, 120, { _, _, _, _, _ in }, nil)
        }
        guard result == kDNSServiceErr_NoError, DNSServiceSetDispatchQueue(connection, .main) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(connection)
            return
        }
        service = connection
        self.address = address
        var registration: DNSServiceRef?
        let registered = DNSServiceRegister(&registration, DNSServiceFlags(kDNSServiceFlagsNoAutoRename), if_nametoindex(interface), "macOSDocker", "_smb._tcp", "local.", "macosdocker.local.", UInt16(445).bigEndian, 0, nil, { _, _, error, name, type, domain, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let owner = Unmanaged<VMHostname>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError, let name, let type, let domain else {
                    owner.serviceHost = nil
                    return
                }
                owner.serviceHost = [String(cString: name), String(cString: type), String(cString: domain)].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.joined(separator: ".")
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        if registered == kDNSServiceErr_NoError, let registration {
            if DNSServiceSetDispatchQueue(registration, .main) == kDNSServiceErr_NoError {
                smbService = registration
            } else {
                DNSServiceRefDeallocate(registration)
            }
        }
    }

    func stop() {
        if let smbService { DNSServiceRefDeallocate(smbService) }
        smbService = nil
        serviceHost = nil
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        address = nil
    }
}
