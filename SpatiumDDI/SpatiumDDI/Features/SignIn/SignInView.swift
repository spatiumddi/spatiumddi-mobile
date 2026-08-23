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
                    LabeledContent("Server", value: model.address.displayName)
                    Button("Change Server", action: onChangeServer)
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

                    Button {
                        model.isScanning = true
                    } label: {
                        Label("Scan Enrolment Code", systemImage: "qrcode.viewfinder")
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

                if let reason = model.biometryUnavailableReason {
                    Section {
                        Label(reason, systemImage: "lock.slash.fill")
                            .foregroundStyle(.red)
                    } footer: {
                        Text(
                            "A token is only stored behind a biometric lock. Set up biometrics and a device passcode to continue."
                        )
                    }
                } else {
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
