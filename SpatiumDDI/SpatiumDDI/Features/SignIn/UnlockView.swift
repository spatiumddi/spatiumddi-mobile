//
//  UnlockView.swift
//  SpatiumDDI
//

import SwiftUI

/// Shown when a token is already stored for this server and needs unsealing.
struct UnlockView: View {
    let address: ServerAddress
    let biometryDescription: String
    let message: String?
    let onUnlock: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(.brandMark)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(address.displayName)
                    .font(.headline)
                Text("Unlock with \(biometryDescription) to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button(action: onUnlock) {
                Label("Unlock", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()

            Button("Sign Out", role: .destructive, action: onSignOut)
                .padding(.bottom, 24)
        }
        .padding()
    }
}

#Preview {
    UnlockView(
        address: ServerAddress(host: "ddi.internal.example", port: 8443),
        biometryDescription: "Face ID",
        message: nil,
        onUnlock: {}, onSignOut: {}
    )
}
