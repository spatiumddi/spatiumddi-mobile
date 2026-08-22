//
//  ConnectionModel.swift
//  SpatiumDDI
//

import Foundation
import Observation

/// Drives "point this app at a control plane", including the trust conversation.
@Observable
final class ConnectionModel {
    enum State: Equatable {
        case idle
        case connecting
        case connected(ServerAddress, status: Int)
        case maintenance(ServerAddress, retryAfter: TimeInterval?)
        case failed(String)
    }

    /// A certificate awaiting the operator's judgement.
    struct PendingTrust: Identifiable, Equatable {
        let id = UUID()
        let certificate: CertificateInfo
        let address: ServerAddress
    }

    var addressInput: String = ""
    private(set) var state: State = .idle
    var pendingTrust: PendingTrust?

    private let probe: ControlPlaneProbe
    private let trustStore: TrustStore

    init(trustStore: TrustStore = TrustStore()) {
        self.trustStore = trustStore
        self.probe = ControlPlaneProbe(trustStore: trustStore)
    }

    var isBusy: Bool { state == .connecting }

    func connect() async {
        let address: ServerAddress
        do {
            address = try ServerAddress.parse(addressInput)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        state = .connecting
        await attempt(address)
    }

    /// The operator vouched for the certificate. Pin it and retry — the same
    /// handshake now takes the pinned path instead of being refused.
    func approvePendingTrust() async {
        guard let pending = pendingTrust else { return }
        pendingTrust = nil

        do {
            try trustStore.pin(pending.certificate.fingerprint, for: pending.address)
        } catch {
            state = .failed("Couldn't save the trust decision. \(error.localizedDescription)")
            return
        }

        state = .connecting
        await attempt(pending.address)
    }

    func declinePendingTrust() {
        pendingTrust = nil
        state = .failed("Connection refused — the server's certificate wasn't trusted.")
    }

    /// Drops a previously approved certificate, so the next connection re-asks.
    func forgetTrust(for address: ServerAddress) {
        try? trustStore.removePin(for: address)
        state = .idle
    }

    private func attempt(_ address: ServerAddress) async {
        switch await probe.probe(address) {
        case .reachable(let status):
            state = .connected(address, status: status)
        case .maintenance(let retryAfter):
            state = .maintenance(address, retryAfter: retryAfter)
        case .trustRequired(let certificate):
            state = .idle
            pendingTrust = PendingTrust(certificate: certificate, address: address)
        case .failed(let error):
            state = .failed(error.localizedDescription)
        }
    }
}
