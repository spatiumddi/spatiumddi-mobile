//
//  Permissions.swift
//  SpatiumDDI
//

import Foundation
import SpatiumAPI

/// What this account is granted, as the control plane reports it.
///
/// **This is UX, not security** — non-negotiable #4. The server enforces every
/// one of these independently and will return a 403 regardless of what the app
/// decided to show. Hiding an Allocate button from someone who cannot allocate
/// saves them a pointless round trip; it does not stop anybody doing anything,
/// and every write path still handles a 403 honestly rather than assuming this
/// check already ruled it out.
///
/// The grammar is `docs/PERMISSIONS.md` in the platform repo: an entry is
/// `{action, resource_type, resource_id?}`, `admin` implies read + write +
/// delete for its type, `*` matches any action, and an entry with no
/// `resource_id` covers every instance of the type.
@MainActor
@Observable
final class Permissions {
    private(set) var isSuperadmin = false
    private(set) var grants: [Components.Schemas.PermissionGrant] = []
    /// Whether the grant list was actually read.
    private(set) var isKnown = false

    init() {}

    /// A known grant list, for previews and tests.
    init(isSuperadmin: Bool, grants: [Components.Schemas.PermissionGrant]) {
        self.isSuperadmin = isSuperadmin
        self.grants = grants
        self.isKnown = true
    }

    /// Whether a write of `resourceType` should be offered.
    ///
    /// Fails **open**. An unread grant list means the app doesn't know, and the
    /// honest response to not knowing is to let the operator try and let the
    /// server answer — a 403 with a reason beats a button that silently isn't
    /// there, which looks like the feature was never built.
    func canWrite(_ resourceTypes: String..., id: String? = nil) -> Bool {
        guard isKnown else { return true }
        if isSuperadmin { return true }
        return resourceTypes.contains { allows(action: "write", type: $0, id: id) }
    }

    private func allows(action: String, type: String, id: String?) -> Bool {
        grants.contains { grant in
            guard grant.resourceType == type else { return false }
            // A grant scoped to one UUID says nothing about any other row.
            if let scoped = grant.resourceId, !scoped.isEmpty, scoped != id { return false }
            switch grant.action {
            case action, "*", "admin": return true
            default: return false
            }
        }
    }

    func load(from session: ControlPlaneSession) async {
        let response = try? await session.client.getMyPermissionsApiV1AuthMePermissionsGet()
        guard case .ok(let ok) = response, let permissions = try? ok.body.json else { return }
        isSuperadmin = permissions.isSuperadmin
        grants = permissions.grants
        isKnown = true
    }
}
