//
//  AppRootView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

struct AppRootView: View {
    @State private var flow = AppFlowModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .animation(.default, value: flow.stage)
            .onChange(of: scenePhase) { _, phase in
                // Lock as the app leaves the foreground, not when it returns —
                // the token must not be resident while the app is backgrounded.
                if phase != .active { flow.lockForBackground() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.stage {
        case .chooseServer:
            ServerSetupView { address, scannedToken in
                flow.connected(to: address, pendingToken: scannedToken)
            }

        case .signIn(let address):
            SignInView(
                model: SignInModel(address: address, prefilledToken: flow.pendingToken) { token in
                    flow.signedIn(with: token, to: address)
                },
                onChangeServer: { flow.changeServer() }
            )

        case .locked(let address, let message):
            UnlockView(
                address: address,
                biometryDescription: flow.biometryDescription,
                message: message,
                onUnlock: { Task { await flow.unlock() } },
                onSignOut: { flow.signOut() }
            )
            // Keyed on the scene phase, not a bare `.task`: locking happens the
            // moment the app stops being active, so a plain on-appear prompt
            // fires while the app is backgrounded, is cancelled by the system,
            // and never comes back. Re-running on the way to `.active` asks at
            // the only moment biometry can actually succeed.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await flow.unlock()
            }

        case .signedIn(let address):
            if let token = flow.token {
                SignedInView(
                    address: address,
                    token: token,
                    onSignOut: { flow.signOut() },
                    onChangeServer: { flow.changeServer() },
                    onSessionRejected: { flow.sessionRejected() }
                )
            } else {
                // Only reachable if the token was dropped between the state
                // change and this render; locking is the honest response.
                ProgressView().task { flow.lockForBackground() }
            }
        }
    }
}

/// The signed-in shell.
///
/// Only the surfaces that are actually built appear here — an app for production
/// networking should not show a screen implying it knows something it does not.
struct SignedInView: View {
    let address: ServerAddress
    let token: String
    let onSignOut: () -> Void
    let onChangeServer: () -> Void
    /// Called when the server rejects the credential this session was built with.
    let onSessionRejected: () -> Void

    /// Built once and torn down explicitly.
    ///
    /// A `URLSession` with a delegate holds that delegate until it is
    /// invalidated, so constructing the session inline in `body` — which SwiftUI
    /// re-evaluates freely — leaks a session and a `ServerTrustDelegate` every
    /// time it runs. State that owns a resource has to outlive a render.
    @State private var session: ControlPlaneSession?

    /// Which section the sidebar has selected. Optional because a collapsed
    /// split view starts with nothing pushed.
    @State private var section: AppSection? = .overview

    var body: some View {
        Group {
            if let session {
                NavigationSplitView {
                    List(selection: $section) {
                        ForEach(AppSection.Group.allCases) { group in
                            Section(group.rawValue) {
                                ForEach(group.sections) { item in
                                    Label(item.title, systemImage: item.symbol).tag(item)
                                }
                            }
                        }
                    }
                    .navigationTitle("SpatiumDDI")
                } detail: {
                    // A NavigationStack here is the documented split-view
                    // pattern: SwiftUI merges it with the sidebar's stack when
                    // the layout collapses on a phone, so pushes still get
                    // exactly one back button.
                    NavigationStack {
                        detail(for: section, session: session)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: token) {
            session?.invalidate()
            session = ControlPlaneSession(address: address, token: token) {
                // The middleware runs on whatever queue the response arrived on.
                Task { @MainActor in onSessionRejected() }
            }
        }
        .onDisappear {
            session?.invalidate()
            session = nil
        }
    }

    @ViewBuilder
    private func detail(for section: AppSection?, session: ControlPlaneSession) -> some View {
        switch section {
        case .overview, nil:
            OverviewView(session: session)
        case .alerts:
            AlertsView(session: session)
        case .ipam:
            IPAMBrowseView(session: session)
        case .dns:
            DNSBrowseView(session: session)
        case .dhcp:
            DHCPBrowseView(session: session)
        case .search:
            SearchView(session: session)
        case .server:
            ServerDetailView(
                address: session.address,
                session: session,
                onSignOut: onSignOut,
                onChangeServer: onChangeServer
            )
        }
    }
}

/// Connection, identity and session controls.
struct ServerDetailView: View {
    let address: ServerAddress
    let session: ControlPlaneSession
    let onSignOut: () -> Void
    let onChangeServer: () -> Void

    @State private var identity: LoadState<Components.Schemas.AppApiV1AuthRouterUserResponse> = .idle
    @State private var permissions: LoadState<Components.Schemas.MyPermissionsResponse> = .idle

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Server", value: address.displayName)
                LabeledContent("Built against", value: SupportedServer.minimum.displayName)
            }

            Section("Signed in as") {
                LoadStateView(
                    state: identity,
                    emptyMessage: "The server didn't return an identity.",
                    retry: { Task { await fetchIdentity() } }
                ) { me in
                    LabeledContent("User", value: me.displayName.isEmpty ? me.username : me.displayName)
                    LabeledContent("Username", value: me.username)
                    if !me.email.isEmpty { LabeledContent("Email", value: me.email) }
                    LabeledContent("Auth source", value: me.authSource)
                    if me.forcePasswordChange {
                        Label(
                            "This account must change its password on the web console.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                LoadStateView(
                    state: permissions,
                    emptyMessage: "This account has no grants.",
                    retry: { Task { await fetchPermissions() } }
                ) { permissions in
                    if permissions.isSuperadmin {
                        Label("Superadmin — every action on every resource.", systemImage: "key.fill")
                            .foregroundStyle(.orange)
                    } else if permissions.grants.isEmpty {
                        // LoadStateView's empty message cannot fire here — the
                        // response is an object, not a collection — so an
                        // account with no grants would otherwise get a blank
                        // section and no explanation for why every other screen
                        // is empty too.
                        Label(
                            "This account has no grants. Most screens will stay empty until an administrator gives it read access.",
                            systemImage: "lock.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    } else {
                        ForEach(Array(permissions.grants.enumerated()), id: \.offset) { _, grant in
                            LabeledContent(grant.resourceType) {
                                Text(grant.action).font(.caption.monospaced())
                            }
                        }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                // Non-negotiable #4, said out loud rather than only honoured in
                // code: this list is what the app uses to decide what to show,
                // and it is not what stops anyone doing anything.
                Text(
                    "The server enforces these independently. What this app shows or hides is a convenience, not a security boundary."
                )
            }

            Section {
                Button("Change Server", action: onChangeServer)
                Button("Sign Out", role: .destructive, action: onSignOut)
            } footer: {
                Text("Signing out deletes this device's stored token for \(address.displayName).")
            }
        }
        .navigationTitle("Server")
        .refreshable { await refresh() }
        .task { if case .idle = identity { await refresh() } }
    }

    private func refresh() async {
        async let a: Void = fetchIdentity()
        async let b: Void = fetchPermissions()
        _ = await (a, b)
    }

    private func fetchIdentity() async {
        identity = .loading
        identity = await LoadState.fetching {
            switch try await session.client.getMeApiV1AuthMeGet() {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let statusCode, _): throw APIStatusError(status: statusCode)
            }
        }
    }

    private func fetchPermissions() async {
        permissions = .loading
        permissions = await LoadState.fetching {
            switch try await session.client.getMyPermissionsApiV1AuthMePermissionsGet() {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let statusCode, _): throw APIStatusError(status: statusCode)
            }
        }
    }
}
