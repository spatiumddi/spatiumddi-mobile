//
//  CertificateAndWakeTools.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// What certificate a host is actually presenting, right now.
///
/// The Certificates section tracks the endpoints somebody remembered to add.
/// This answers the same question about anything at all, which is what you
/// want when a browser has just complained about a host nobody is monitoring.
struct TLSCertToolView: View {
    let session: ControlPlaneSession

    @State private var host = ""
    @State private var port = "443"
    @State private var serverName = ""
    @State private var run = ToolRun<Components.Schemas.TlsCertResult>()

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var portNumber: Int? { PortNumber.parse(port) }

    var body: some View {
        Form {
            Section {
                TextField("Host or IP", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                TextField("SNI name (optional)", text: $serverName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                ToolRunButton(
                    title: "Fetch Certificate",
                    isRunning: run.isRunning,
                    isEnabled: !trimmedHost.isEmpty && portNumber != nil,
                    action: start
                )
            } footer: {
                if trimmedHost.isEmpty {
                    Text("Enter a host name or an IP address first.")
                } else if portNumber == nil {
                    Text("Enter a port between 1 and 65535.")
                } else {
                    Text("Set an SNI name to ask for a specific certificate on a shared address.")
                }
            }

            ToolResultSection(
                run: run, idleMessage: "Enter a host to see the certificate it presents."
            ) { result in
                certificate(result)
            }
        }
        .navigationTitle("TLS Certificate")
        .navigationBarTitleDisplayMode(.inline)
        .dismissableKeyboard()
    }

    @ViewBuilder
    private func certificate(_ result: Components.Schemas.TlsCertResult) -> some View {
        // The verdict first. Everything below is the evidence for it.
        let verdict = CertificateVerdict.of(
            expired: result.expired,
            hostnameMatches: result.hostnameMatches,
            selfSigned: result.selfSigned,
            ok: result.ok
        )
        LabeledContent("Verdict") {
            Label {
                Text(verdict.label)
            } icon: {
                Image(
                    systemName: verdict.isGood
                        ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                )
            }
            .foregroundStyle(verdict.isGood ? .green : .orange)
        }

        if let error = result.error, !error.isEmpty {
            Label {
                Text(verbatim: error)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
            }
            .foregroundStyle(.red)
        }

        if let days = result.daysRemaining {
            LabeledContent("Expires in") {
                Text("\(days) days")
                    // Same thresholds the Certificates section uses, so the
                    // two screens never disagree about what "soon" means.
                    .foregroundStyle(Expiry(daysRemaining: days).tint)
            }
        }
        if let notAfter = result.notAfter, !notAfter.isEmpty {
            LabeledContent("Not after") { Text(verbatim: notAfter) }
        }
        if let notBefore = result.notBefore, !notBefore.isEmpty {
            LabeledContent("Not before") { Text(verbatim: notBefore) }
        }
        if let subject = result.subject, !subject.isEmpty {
            LabeledContent("Subject") { Text(verbatim: subject).font(.caption.monospaced()) }
        }
        if let issuer = result.issuer, !issuer.isEmpty {
            LabeledContent("Issuer") { Text(verbatim: issuer).font(.caption.monospaced()) }
        }
        if let algorithm = result.signatureAlgorithm, !algorithm.isEmpty {
            LabeledContent("Signature") { Text(verbatim: algorithm) }
        }
        if let serial = result.serial, !serial.isEmpty {
            LabeledContent("Serial") {
                Text(verbatim: serial).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        if let san = result.san, !san.isEmpty {
            LabeledContent("Names") {
                Text(verbatim: san.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        ToolProvenanceView(ranFrom: result.ranFrom)
    }

    private func start() {
        guard !trimmedHost.isEmpty, let portNumber else { return }
        dismissKeyboard()
        let host = trimmedHost
        let sni = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await run.run {
                let body = Components.Schemas.TlsCertRequest(
                    host: host, port: portNumber, serverName: sni.isEmpty ? nil : sni
                )
                switch try await session.client.tlsCertApiV1ToolsTlsCertPost(body: .json(body)) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        }
    }
}

/// Switch a machine on from wherever you are.
///
/// The one tool here that changes anything, so the one that confirms — and it
/// confirms by naming the MAC, because a magic packet sent to the wrong
/// address is silent: nothing wakes, nothing errors, and there is no way to
/// tell from the result which of those happened.
///
/// `sent` means the packet left the control plane. It does **not** mean the
/// machine woke, and the screen says so rather than letting a green tick imply
/// something nobody checked.
struct WakeOnLANToolView: View {
    let session: ControlPlaneSession

    @State private var mac = ""
    @State private var broadcast = ""
    @State private var isConfirming = false
    @State private var run = ToolRun<Components.Schemas.WolResult>()

    private var trimmedMAC: String { mac.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("MAC address", text: $mac)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .font(.body.monospaced())
                TextField("Broadcast address (optional)", text: $broadcast)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .font(.body.monospaced())
                ToolRunButton(
                    title: "Wake",
                    isRunning: run.isRunning,
                    isEnabled: !trimmedMAC.isEmpty,
                    action: { isConfirming = true }
                )
            } footer: {
                if trimmedMAC.isEmpty {
                    Text("Enter the MAC address of the machine to wake.")
                } else {
                    Text(
                        "A magic packet only reaches the broadcast domain it is sent into, so a machine on another subnet needs its broadcast address here."
                    )
                }
            }

            ToolResultSection(run: run, idleMessage: "Enter a MAC address to send a magic packet.") {
                result in
                LabeledContent("Packet") {
                    Label {
                        Text(result.sent ? "Sent" : "Not sent")
                    } icon: {
                        Image(systemName: result.sent ? "paperplane.fill" : "xmark.octagon.fill")
                    }
                    .foregroundStyle(result.sent ? .green : .red)
                }
                LabeledContent("To") {
                    Text(verbatim: result.mac).font(.body.monospaced())
                }
                LabeledContent("Broadcast") {
                    Text(verbatim: "\(result.broadcast):\(result.port)").font(.caption.monospaced())
                }
                if let error = result.error, !error.isEmpty {
                    Label {
                        Text(verbatim: error)
                    } icon: {
                        Image(systemName: "xmark.octagon.fill")
                    }
                    .foregroundStyle(.red)
                }
                if result.sent {
                    Text(
                        "The packet left the control plane. Whether the machine wakes depends on it, and nothing here can tell you."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ToolProvenanceView(ranFrom: result.ranFrom)
            }
        }
        .navigationTitle("Wake on LAN")
        .navigationBarTitleDisplayMode(.inline)
        .dismissableKeyboard()
        .alert("Wake this machine?", isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) {}
            Button("Wake") { start() }
        } message: {
            Text(verbatim: confirmation)
        }
    }

    private var confirmation: String {
        let target = broadcast.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination =
            target.isEmpty
            ? String(localized: "on the control plane's own broadcast domain")
            : String(localized: "to \(target)")
        return String(localized: "A magic packet goes to \(trimmedMAC), \(destination).")
    }

    private func start() {
        guard !trimmedMAC.isEmpty else { return }
        dismissKeyboard()
        let mac = trimmedMAC
        let target = broadcast.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await run.run {
                let body = Components.Schemas.WolToolRequest(
                    broadcast: target.isEmpty ? nil : target, mac: mac
                )
                switch try await session.client.wolWakeApiV1ToolsWolPost(body: .json(body)) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        }
    }
}
