//
//  AppRootView.swift
//  SpatiumDDI
//

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
            ServerSetupView { address in flow.connected(to: address) }

        case .signIn(let address):
            SignInView(
                model: SignInModel(address: address) { token in
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
            .task { await flow.unlock() }

        case .signedIn(let address):
            if let token = flow.token {
                SignedInView(
                    session: ControlPlaneSession(address: address, token: token),
                    onSignOut: { flow.signOut() },
                    onChangeServer: { flow.changeServer() }
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
/// Only the surfaces that are actually built appear here. Tabs for DNS, DHCP and
/// alerts arrive with their views rather than as empty placeholders — an app for
/// production networking should not show a screen implying it knows something it
/// does not.
struct SignedInView: View {
    let session: ControlPlaneSession
    let onSignOut: () -> Void
    let onChangeServer: () -> Void

    var body: some View {
        TabView {
            Tab("IPAM", systemImage: "square.grid.3x3") {
                NavigationStack { IPAMBrowseView(session: session) }
            }
            Tab("Server", systemImage: "gear") {
                NavigationStack {
                    ServerDetailView(
                        address: session.address,
                        onSignOut: onSignOut,
                        onChangeServer: onChangeServer
                    )
                }
            }
        }
    }
}

/// Connection and session controls.
struct ServerDetailView: View {
    let address: ServerAddress
    let onSignOut: () -> Void
    let onChangeServer: () -> Void

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Server", value: address.displayName)
                LabeledContent("Session", value: "Authenticated")
            }

            Section {
                Button("Change Server", action: onChangeServer)
                Button("Sign Out", role: .destructive, action: onSignOut)
            } footer: {
                Text("Signing out deletes this device's stored token for \(address.displayName).")
            }
        }
        .navigationTitle("Server")
    }
}
