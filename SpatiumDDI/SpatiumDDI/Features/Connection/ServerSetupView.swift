//
//  ServerSetupView.swift
//  SpatiumDDI
//

import SwiftUI

/// Where an operator points the app at their control plane.
struct ServerSetupView: View {
    /// Called once the operator has a reachable, trusted server, with any token
    /// the same enrolment code supplied.
    var onConnected: (ServerAddress, String?) -> Void = { _, _ in }

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
                    Text("A host name or IP address. Add a port if your control plane doesn't use 443.")
                }

                Section {
                    // First thing on the first screen, because the enrolment
                    // code carries the server address as well as the token —
                    // typing a hostname on a phone is the worst part of setting
                    // this up, and the code removes it.
                    Button {
                        addressFocused = false
                        model.isScanning = true
                    } label: {
                        Label("Scan Enrolment Code", systemImage: "qrcode.viewfinder")
                    }
                    if let notice = model.scanNotice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
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
            .sheet(isPresented: $model.isScanning) {
                TokenScannerView(
                    onScanned: { model.apply($0) },
                    onCancel: { model.isScanning = false }
                )
            }
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
                Button("Continue") { onConnected(address, model.scannedToken) }
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
