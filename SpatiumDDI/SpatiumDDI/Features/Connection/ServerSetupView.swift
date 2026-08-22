//
//  ServerSetupView.swift
//  SpatiumDDI
//

import SwiftUI

/// Where an operator points the app at their control plane.
struct ServerSetupView: View {
    @State private var model = ConnectionModel()
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ddi.internal.example", text: $model.addressInput)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit { Task { await model.connect() } }
                } header: {
                    Text("Server Address")
                } footer: {
                    if model.warnsAboutPlaintext {
                        Label(
                            "http:// sends your credentials in the clear. iOS also blocks it except on a local network.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    } else {
                        Text("A host name or IP address. Add a port if your control plane doesn't use 443.")
                    }
                }

                Section {
                    Button {
                        addressFocused = false
                        Task { await model.connect() }
                    } label: {
                        HStack {
                            Text("Connect")
                            Spacer()
                            if model.isBusy { ProgressView() }
                        }
                    }
                    .disabled(model.addressInput.isEmpty || model.isBusy)
                }

                statusSection
            }
            .navigationTitle("Connect")
            .sheet(item: $model.pendingTrust) { pending in
                CertificateTrustSheet(
                    pending: pending,
                    onTrust: { Task { await model.approvePendingTrust() } },
                    onCancel: { model.declinePendingTrust() }
                )
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.state {
        case .idle, .connecting:
            EmptyView()

        case .connected(let address, let status):
            Section("Status") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reachable").font(.body)
                        Text("\(address.displayName) · HTTP \(status)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
                Button("Forget Trusted Certificate", role: .destructive) {
                    model.forgetTrust(for: address)
                }
            }

        case .maintenance(let address, let retryAfter):
            Section("Status") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Maintenance in progress")
                        Text(maintenanceDetail(address: address, retryAfter: retryAfter))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                }
            }

        case .failed(let message):
            Section("Status") {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
        }
    }

    /// Reported, never acted on — the app does not retry into a change window.
    private func maintenanceDetail(address: ServerAddress, retryAfter: TimeInterval?) -> String {
        guard let retryAfter else { return "\(address.displayName) is in a change window." }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        let phrase = formatter.string(from: retryAfter) ?? "a while"
        return "\(address.displayName) · try again in \(phrase)."
    }
}

#Preview {
    ServerSetupView()
}
