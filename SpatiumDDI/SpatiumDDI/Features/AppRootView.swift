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
            SignedInView(
                address: address,
                onSignOut: { flow.signOut() },
                onChangeServer: { flow.changeServer() }
            )
        }
    }
}

/// Placeholder for the Phase 1 surfaces.
///
/// Deliberately not a mocked-up dashboard: every read view — KPIs, IPAM, DNS,
/// DHCP, alerts — decodes response payloads, which waits on the generated
/// client. Showing invented numbers for an app that manages production
/// networking would be worse than showing none.
struct SignedInView: View {
    let address: ServerAddress
    let onSignOut: () -> Void
    let onChangeServer: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Server", value: address.displayName)
                    LabeledContent("Session", value: "Authenticated")
                }

                Section {
                    Label(
                        "Dashboard, IPAM, DNS, DHCP and alerts arrive with the generated API client.",
                        systemImage: "clock.badge.checkmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Next")
                }

                Section {
                    Button("Change Server", action: onChangeServer)
                    Button("Sign Out", role: .destructive, action: onSignOut)
                }
            }
            .navigationTitle("SpatiumDDI")
        }
    }
}
