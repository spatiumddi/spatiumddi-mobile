//
//  FeatureModules.swift
//  SpatiumDDI
//

import Foundation
import SpatiumAPI

/// Which of the platform's optional modules this control plane has switched on.
///
/// This is the answer to CLAUDE.md's rule against feature-probing. The platform
/// ships 52 togglable modules and returns **404** from every endpoint belonging
/// to a disabled one — the same status an RBAC-filtered surface returns, and the
/// same status a genuinely deleted row returns. Calling an endpoint to find out
/// whether it exists cannot distinguish those three, so the app asks instead.
///
/// A lab with only nine modules enabled is not unusual; showing sixteen sidebar
/// entries where nine of them can only ever say "switched off" would make the
/// app look broken rather than correctly configured.
@MainActor
@Observable
final class FeatureModules {
    /// Module ids that are enabled. Empty until loaded.
    private(set) var enabled: Set<String> = []
    /// Whether the list was actually read. Until it is, nothing is hidden.
    private(set) var isKnown = false

    /// Whether a section gated on `module` should be offered.
    ///
    /// Fails **open**: an ungated section, or an unknown module list, shows the
    /// section. `/admin/feature-modules` is an admin endpoint, so a non-admin
    /// operator cannot read it — and hiding half the app from them because a
    /// permission check failed would be far worse than letting a screen report
    /// its own 404 honestly.
    func isAvailable(_ module: String?) -> Bool {
        guard let module, isKnown else { return true }
        return enabled.contains(module)
    }

    func load(from session: ControlPlaneSession) async {
        let response = try? await session.client.listFeatureModulesApiV1AdminFeatureModulesGet()
        guard case .ok(let ok) = response, let modules = try? ok.body.json else { return }
        enabled = Set(modules.filter(\.enabled).map(\.id))
        isKnown = true
    }
}
