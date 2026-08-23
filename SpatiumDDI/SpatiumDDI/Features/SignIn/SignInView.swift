//
//  SignInView.swift
//  SpatiumDDI
//

import SwiftUI

struct SignInView: View {
    @State var model: SignInModel
    let onChangeServer: () -> Void

    /// Whether the token is currently legible.
    ///
    /// Off by default, and reset whenever the app leaves the foreground — a
    /// revealed credential should not survive on a screen the operator walked
    /// away from.
    @State private var isTokenRevealed = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                BrandHeader()

                Section {
                    LabeledContent("Server") {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(verbatim: model.server.displayName)
                            if let subtitle = model.server.subtitle {
                                Text(verbatim: subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Switch Server", action: onChangeServer)
                        .disabled(model.isBusy)
                }

                Section {
                    HStack {
                        Group {
                            if isTokenRevealed {
                                TextField("sddi_…", text: $model.tokenInput)
                            } else {
                                SecureField("sddi_…", text: $model.tokenInput)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(isTokenRevealed ? .body.monospaced() : .body)

                        Button {
                            isTokenRevealed.toggle()
                        } label: {
                            Image(systemName: isTokenRevealed ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isTokenRevealed ? "Hide token" : "Show token")
                    }

                    // Below the field, not instead of it. Scanning is a
                    // convenience; pasting a token is the ordinary path and
                    // has to keep looking like one.
                    Button {
                        model.isScanning = true
                    } label: {
                        Label("Or scan an enrolment code", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(model.isBusy)

                    if let notice = model.scanNotice {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("API Token")
                } footer: {
                    if !model.tokenInput.isEmpty && !model.looksLikeAToken {
                        Label(
                            "That doesn't look like an API token or a JWT. Check what you pasted.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    } else {
                        Text(
                            "Create a token in the SpatiumDDI web UI under your account settings, then paste it here."
                        )
                    }
                }

                // Shown in every case, including the good one — the operator is
                // about to hand this app a credential for production DNS, and
                // what will be holding it is not a detail to leave implicit.
                Section {
                    DeviceProtectionNotice(protection: model.availableProtection)
                } footer: {
                    if model.isDeviceUnprotected {
                        Text(
                            "A token is never stored unprotected. Set a device passcode — and biometrics if this device has them — then come back."
                        )
                    }
                }

                if !model.isDeviceUnprotected {
                    Section {
                        Button {
                            Task { await model.signIn() }
                        } label: {
                            HStack {
                                Text(model.state == .storing ? "Saving…" : "Sign In")
                                Spacer()
                                if model.isBusy { ProgressView() }
                            }
                        }
                        .disabled(model.tokenInput.isEmpty || model.isBusy)
                    } footer: {
                        Text(
                            "The token is stored in the Keychain and unlocked with \(model.biometryDescription). It never leaves this device except as an Authorization header to \(model.address.displayName)."
                        )
                    }
                }

                if case .failed(let message) = model.state {
                    Section("Status") {
                        Label {
                            Text(message)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Sign In")
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { isTokenRevealed = false }
            }
            .sheet(isPresented: $model.isScanning) {
                TokenScannerView(
                    onScanned: { model.apply($0) },
                    onCancel: { model.isScanning = false }
                )
            }
        }
    }
}
