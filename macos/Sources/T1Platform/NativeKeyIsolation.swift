import AppKit
import IOKit.hid
import IOKit.hidsystem
import OSLog

struct NativeKeyMap {
    typealias Entry = [String: UInt64]
    private static let source = "HIDKeyboardModifierMappingSrc"
    private static let destination = "HIDKeyboardModifierMappingDst"
    private static let keyboard: UInt64 = 0x700000000

    static func mute(_ keys: Set<HIDKey>) -> [Entry] {
        keys.filter(\.supportsNativeIsolation).sorted { $0.encoded < $1.encoded }.map {
            [source: $0.encoded, destination: keyboard]
        }
    }

    static func isOwnedEntry(_ entry: Entry) -> Bool {
        guard entry.count == 2, let value = entry[source], entry[destination] == keyboard else { return false }
        return HIDKey(page: UInt32(truncatingIfNeeded: value >> 32), usage: UInt32(truncatingIfNeeded: value)).supportsNativeIsolation
    }

    static func reconcile(_ existing: [Entry], owned: [Entry], desired: [Entry]) -> (merged: [Entry], owned: [Entry]) {
        // An existing mapping for the same source belongs to its author.
        let retained = existing.filter { !owned.contains($0) }
        let reserved = Set(retained.compactMap { $0[source] })
        let added = desired.filter { entry in entry[source].map { !reserved.contains($0) } == true }
        return (retained + added, added)
    }
}

/// Applies keyboard and consumer-key maps to one independently identified remote collection.
@MainActor
public final class NativeKeyIsolation {
    private struct Lease: Codable, Equatable {
        let registryID: UInt64
        let entries: [NativeKeyMap.Entry]
    }

    private struct Journal: Codable {
        let bootSession: String
        let leases: [Lease]
    }

    private var client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private let log = Logger(subsystem: "local.t1controller.app", category: "NativeIsolation")
    private var lastServiceIDs: Set<UInt64> = []
    private let journal: URL
    private let bootSession: String?
    private let lock: Int32
    private var leases: [Lease] = []
    private var verified: [String: (IOHIDServiceClient, [NativeKeyMap.Entry])] = [:]
    private var termination: (any NSObjectProtocol)?
    public private(set) var restoreFailed = false
    public var canManage: Bool { lock >= 0 && bootSession != nil }

    public convenience init() {
        self.init(stateDirectory: URL.applicationSupportDirectory.appending(path: "T1Controller", directoryHint: .isDirectory))
    }

    init(stateDirectory directory: URL) {
        journal = directory.appending(path: "return-key-isolation.json", directoryHint: .notDirectory)
        bootSession = Self.currentBootSession()
        lock = Self.acquireLock(in: directory)
        if lock >= 0, let data = try? Data(contentsOf: journal),
           let saved = try? JSONDecoder().decode(Journal.self, from: data), saved.bootSession == bootSession {
            leases = saved.leases.map { Lease(registryID: $0.registryID, entries: $0.entries.filter(NativeKeyMap.isOwnedEntry)) }
        }
        termination = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh([:]) }
        }
    }

    isolated deinit {
        if let termination { NotificationCenter.default.removeObserver(termination) }
        if lock >= 0 {
            refresh([:])
            close(lock)
        }
    }

    public func refresh(_ requested: [HIDDevice: Set<HIDKey>]) {
        guard lock >= 0 else { return }
        restoreFailed = false
        // An unscheduled simple client retains its original service snapshot.
        // KMFU routing and USB reconnects replace the services, even when the
        // receiver keeps the same location and fingerprint. Rediscover through
        // a new connection, and retain it while its verified services are used.
        verified.removeAll()
        client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        let keyboards = services.compactMap { service -> (UInt64, IOHIDServiceClient)? in
            guard Self.isRemote(service),
                  let registryID = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
            else { return nil }
            return (registryID, service)
        }

        let serviceIDs = Set(keyboards.map(\.0))
        if serviceIDs != lastServiceIDs {
            let identifiers = serviceIDs.sorted().map { String(format: "0x%llX", $0) }.joined(separator: ",")
            log.notice("Rediscovered remote HID services: \(identifiers, privacy: .public)")
            lastServiceIDs = serviceIDs
        }
        for (id, service) in keyboards {
            let matches = requested.keys.filter { key in
                (key.isDirectT1Receiver || key.isXiaomiBluetoothRemote || key.isChromecastRemote) && key.locationID != 0 &&
                    Self.integer(service, kIOHIDVendorIDKey) == key.vendorID &&
                    Self.integer(service, kIOHIDProductIDKey) == key.productID &&
                    Self.integer(service, kIOHIDPrimaryUsagePageKey) == key.usagePage &&
                    Self.integer(service, kIOHIDPrimaryUsageKey) == key.usage &&
                    Self.integer(service, kIOHIDLocationIDKey) == Int(key.locationID) &&
                    keyboards.filter {
                        Self.integer($0.1, kIOHIDLocationIDKey) == Int(key.locationID) &&
                            Self.integer($0.1, kIOHIDPrimaryUsageKey) == key.usage
                    }.count == 1
            }
            let device = matches.count == 1 ? matches.first : nil
            let desired = NativeKeyMap.mute(device.flatMap { requested[$0] } ?? [])
            let previous = leases.first { $0.registryID == id }?.entries ?? []
            guard !desired.isEmpty || !previous.isEmpty else { continue }
            let needsRestore = previous.contains { !desired.contains($0) }
            guard let map = Self.read(service) else {
                log.error("Cannot read key map for service \(id, privacy: .public)")
                restoreFailed = restoreFailed || needsRestore
                continue
            }
            let change = NativeKeyMap.reconcile(map, owned: previous, desired: desired)

            if change.merged != map {
                // Preserve both sets until a write is confirmed, including retries and partial failures.
                let pending = previous + change.owned.filter { !previous.contains($0) }
                guard record(id, entries: pending) else {
                    restoreFailed = restoreFailed || needsRestore
                    continue
                }
                let accepted = IOHIDServiceClientSetProperty(service, kIOHIDUserKeyUsageMapKey as CFString,
                                                             change.merged as CFArray)
                guard accepted, Self.read(service) == change.merged else {
                    log.error("Key map write/readback failed for service \(id, privacy: .public), accepted=\(accepted, privacy: .public)")
                    restoreFailed = restoreFailed || needsRestore
                    continue
                }
            }
            _ = record(id, entries: change.owned)
            if let device, !change.owned.isEmpty {
                verified[device.id] = (service, change.owned)
            }
        }

    }

    public func isIsolated(_ device: HIDDevice, key: HIDKey) -> Bool {
        guard let (service, owned) = verified[device.id], let target = NativeKeyMap.mute([key]).first,
              owned.contains(target), let current = Self.read(service)
        else { return false }
        return current.contains(target)
    }

    private func record(_ id: UInt64, entries: [NativeKeyMap.Entry]) -> Bool {
        let current = leases.first { $0.registryID == id }?.entries ?? []
        if current == entries { return true }
        var next = leases.filter { $0.registryID != id }
        if !entries.isEmpty { next.append(Lease(registryID: id, entries: entries)) }
        return store(next)
    }

    private func store(_ next: [Lease]) -> Bool {
        guard let bootSession else { return false }
        do {
            try JSONEncoder().encode(Journal(bootSession: bootSession, leases: next)).write(to: journal, options: .atomic)
            leases = next
            return true
        } catch {
            log.error("Cannot save isolation journal: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func currentBootSession() -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        var size = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0, size > 1 else { return nil }
        return String(decoding: buffer.prefix(size - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func acquireLock(in directory: URL) -> Int32 {
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return -1 }
        let fd = open(directory.appending(path: "return-key-isolation.lock").path,
                      O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return -1 }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        close(fd)
        return -1
    }

    private static func integer(_ service: IOHIDServiceClient, _ property: String) -> Int? {
        (IOHIDServiceClientCopyProperty(service, property as CFString) as? NSNumber)?.intValue
    }

    private static func isRemote(_ service: IOHIDServiceClient) -> Bool {
        let vendor = integer(service, kIOHIDVendorIDKey)
        let product = integer(service, kIOHIDProductIDKey)
        let transport = IOHIDServiceClientCopyProperty(service, kIOHIDTransportKey as CFString) as? String
        let usage = integer(service, kIOHIDPrimaryUsageKey)
        guard integer(service, kIOHIDPrimaryUsagePageKey) == 1,
              IOHIDServiceClientConformsTo(service, 1, 6) != 0 || IOHIDServiceClientConformsTo(service, 12, 1) != 0 else { return false }
        return (vendor == 0x1915 && product == 0x1025 && transport == "USB" && (usage == 2 || usage == 6)) ||
            (((vendor == 0x2717 && product == 0x32B8) || (vendor == 0x18D1 && product == 0x9450)) && usage == 6 &&
                (transport == "Bluetooth" || transport == "Bluetooth Low Energy"))
    }

    private static func read(_ service: IOHIDServiceClient) -> [NativeKeyMap.Entry]? {
        guard let property = IOHIDServiceClientCopyProperty(service, kIOHIDUserKeyUsageMapKey as CFString)
        else { return [] }
        return property as? [NativeKeyMap.Entry]
    }
}
