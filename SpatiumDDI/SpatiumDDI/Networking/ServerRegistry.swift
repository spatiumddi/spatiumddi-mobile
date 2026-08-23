//
//  ServerRegistry.swift
//  SpatiumDDI
//

import Foundation

/// One control plane the operator has configured, with the name they gave it.
///
/// The label exists because two hostnames that differ by one character are
/// exactly the pair someone will confuse, and this app is about to grow writes.
/// "Lab" and "Prod EU" are answerable at a glance; `ddi-01.eu.internal` and
/// `ddi-o1.eu.internal` are not.
nonisolated struct StoredServer: Codable, Equatable, Hashable, Identifiable, Sendable {
    var address: ServerAddress
    /// What the operator called it. `nil` or empty means "just show the host".
    var label: String?

    init(address: ServerAddress, label: String? = nil) {
        self.address = address
        self.label = label
    }

    /// Keyed by origin, exactly as the token and the certificate pin are.
    /// Two entries for one `host:port` would share a Keychain item and a pin,
    /// so they are the same server whatever they are called.
    var id: String { address.pinKey }

    /// The trimmed label, or `nil` when there isn't a usable one.
    var trimmedLabel: String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What to call this server in a list or a header.
    var displayName: String { trimmedLabel ?? address.displayName }

    /// The address, shown underneath a label rather than instead of it.
    ///
    /// `nil` when the label *is* the address, so a row doesn't print it twice.
    var subtitle: String? { trimmedLabel == nil ? nil : address.displayName }
}

/// The set of configured control planes, and which one is current.
///
/// Deliberately not a store of anything secret. Non-negotiable #2 keeps every
/// token in the Keychain — one protected item per `host:port`, never a bundle —
/// and `TrustStore` keeps every certificate pin there too, also per `host:port`.
/// What lives here is the operator's own configuration: which servers exist,
/// what they called them, which one they were last on.
///
/// Non-negotiable #3 is untouched by this: none of it is response data.
nonisolated struct ServerRegistry {
    private let defaults: UserDefaults

    private static let serversKey = "servers"
    private static let currentKey = "currentServerID"
    /// What single-server builds wrote. Read once, to migrate.
    private static let legacyAddressKey = "lastServerAddress"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every configured server, in the order they were added.
    ///
    /// Migrates a single-server install on first read: the address it stored
    /// keeps its Keychain token and its certificate pin, both of which are
    /// already keyed by `pinKey`, so the upgrade costs the operator nothing.
    func servers() -> [StoredServer] {
        if let data = defaults.data(forKey: Self.serversKey),
            let stored = try? JSONDecoder().decode([StoredServer].self, from: data)
        {
            return stored
        }

        guard let legacy = defaults.data(forKey: Self.legacyAddressKey),
            let address = try? JSONDecoder().decode(ServerAddress.self, from: legacy)
        else { return [] }

        let migrated = [StoredServer(address: address)]
        save(migrated)
        setCurrentID(migrated[0].id)
        return migrated
    }

    func save(_ servers: [StoredServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: Self.serversKey)
    }

    func currentID() -> String? { defaults.string(forKey: Self.currentKey) }

    func setCurrentID(_ id: String?) {
        if let id {
            defaults.set(id, forKey: Self.currentKey)
        } else {
            defaults.removeObject(forKey: Self.currentKey)
        }
    }
}
