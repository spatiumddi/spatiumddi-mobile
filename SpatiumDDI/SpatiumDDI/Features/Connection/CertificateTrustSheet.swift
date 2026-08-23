//
//  CertificateTrustSheet.swift
//  SpatiumDDI
//

import SwiftUI

/// Asks the operator to vouch for a certificate the system won't validate.
///
/// The fingerprint is the point of this screen. It's laid out to be compared
/// character by character against what the control plane reports, and the
/// approving action is deliberately not the easiest thing to hit.
struct CertificateTrustSheet: View {
    let pending: ConnectionModel.PendingTrust
    let onTrust: () -> Void
    let onCancel: () -> Void

    private var certificate: CertificateInfo { pending.certificate }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("This server's identity can't be verified automatically.")
                    } icon: {
                        Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                } footer: {
                    Text(
                        "Self-hosted control planes usually present a certificate from a private CA. Approve it only if the fingerprint below matches the one your server reports."
                    )
                }

                // Evidence from the scanned code, placed above the fingerprint
                // so it frames the comparison rather than being a footnote to
                // it. A mismatch is stated as loudly as a match.
                if let matches = pending.matchesScannedCode {
                    Section {
                        Label {
                            Text(
                                matches
                                    ? "This certificate matches the fingerprint in the code you scanned."
                                    : "This certificate does NOT match the fingerprint in the code you scanned. Do not continue until you know why."
                            )
                            .font(.callout)
                        } icon: {
                            Image(systemName: matches ? "checkmark.seal.fill" : "xmark.seal.fill")
                        }
                        .foregroundStyle(matches ? .green : .red)
                    }
                }

                Section("SHA-256 Fingerprint") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(certificate.fingerprintGroups, id: \.self) { group in
                            Text(group)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("SHA-256 fingerprint")
                    .accessibilityValue(certificate.fingerprintHex)
                }

                Section("Certificate") {
                    LabeledContent("Subject", value: certificate.subjectSummary ?? "—")
                    LabeledContent("Presented for", value: certificate.requestedHost)
                    LabeledContent("Chain length", value: "\(certificate.chainLength)")
                }

                Section {
                    LabeledContent("Server", value: pending.address.displayName)
                } footer: {
                    Text(
                        "Approving pins this exact certificate for \(pending.address.displayName). If the server later presents a different one, you'll be asked again."
                    )
                }
            }
            .navigationTitle("Verify Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Don't Trust", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust", action: onTrust)
                }
            }
            .interactiveDismissDisabled()
        }
    }
}

#Preview {
    let address = ServerAddress(host: "ddi.internal.example", port: 8443)
    let certificate = CertificateInfo(
        fingerprint: Data((0..<32).map { UInt8($0 &* 7 &+ 11) }),
        subjectSummary: "ddi.internal.example",
        chainLength: 2,
        requestedHost: "ddi.internal.example"
    )
    return Color.clear.sheet(isPresented: .constant(true)) {
        CertificateTrustSheet(
            pending: .init(certificate: certificate, address: address),
            onTrust: {}, onCancel: {}
        )
    }
}
