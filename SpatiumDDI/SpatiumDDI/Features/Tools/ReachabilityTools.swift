//
//  ReachabilityTools.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Ping, traceroute and MTR — one screen, because they are one question asked
/// at three levels of detail: is it there, how do I get to it, and where does
/// it hurt.
///
/// `override_do_not_probe` is deliberately not offered. The platform lets an
/// operator mark a device fragile — a lab PLC that falls over when scanned —
/// and overriding that flag is a decision to make in front of the thing you
/// might knock over, not one-handed from a train. If the server refuses for
/// that reason it says so, and the refusal is shown as written.
struct ReachabilityToolView: View {
    enum Tool: String {
        case ping
        case traceroute
        case mtr

        var title: LocalizedStringResource {
            switch self {
            case .ping: "Ping"
            case .traceroute: "Traceroute"
            case .mtr: "MTR"
            }
        }

        var idleMessage: LocalizedStringResource {
            switch self {
            case .ping: "Enter a host and run it. The control plane pings, not this phone."
            case .traceroute: "Enter a host to see the path the control plane takes to reach it."
            case .mtr: "Enter a host for a per-hop loss and latency report. This one takes a while."
            }
        }

        var prompt: LocalizedStringResource {
            switch self {
            case .ping: "Host or IP to ping"
            case .traceroute: "Host or IP to trace"
            case .mtr: "Host or IP to measure"
            }
        }
    }

    let session: ControlPlaneSession
    let tool: Tool

    @State private var host = ""
    @State private var run = ToolRun<Components.Schemas.CommandResult>()

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                TextField(String(localized: tool.prompt), text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.go)
                    .onSubmit(start)
                ToolRunButton(
                    title: "Run",
                    isRunning: run.isRunning,
                    isEnabled: !trimmedHost.isEmpty,
                    action: start
                )
            } footer: {
                if trimmedHost.isEmpty {
                    // House style: say why the button is disabled, next to the
                    // field at fault.
                    Text("Enter a host name or an IP address first.")
                }
            }

            ToolResultSection(run: run, idleMessage: tool.idleMessage) { result in
                CommandOutputView(result: result)
            }
        }
        .navigationTitle(Text(tool.title))
        .navigationBarTitleDisplayMode(.inline)
        .dismissableKeyboard()
    }

    private func start() {
        guard !trimmedHost.isEmpty else { return }
        // The result is what was asked for; it should not land under the keyboard.
        dismissKeyboard()
        let host = trimmedHost
        Task {
            await run.run {
                let body = Components.Schemas.HostRequest(host: host)
                // Three switches rather than one shared unwrapper: each route
                // generates its own Output enum, so the cases only look alike.
                switch tool {
                case .ping:
                    switch try await session.client.pingApiV1ToolsPingPost(body: .json(body)) {
                    case .ok(let ok): return try ok.body.json
                    case .unprocessableContent: throw APIStatusError(status: 422)
                    case .undocumented(let statusCode, let payload):
                        throw await APIStatusError(status: statusCode, payload: payload)
                    }
                case .traceroute:
                    switch try await session.client.tracerouteApiV1ToolsTraceroutePost(
                        body: .json(body)
                    ) {
                    case .ok(let ok): return try ok.body.json
                    case .unprocessableContent: throw APIStatusError(status: 422)
                    case .undocumented(let statusCode, let payload):
                        throw await APIStatusError(status: statusCode, payload: payload)
                    }
                case .mtr:
                    switch try await session.client.mtrApiV1ToolsMtrPost(body: .json(body)) {
                    case .ok(let ok): return try ok.body.json
                    case .unprocessableContent: throw APIStatusError(status: 422)
                    case .undocumented(let statusCode, let payload):
                        throw await APIStatusError(status: statusCode, payload: payload)
                    }
                }
            }
        }
    }

}

/// Is that port open, from where the service actually lives.
struct PortTestToolView: View {
    let session: ControlPlaneSession

    @State private var host = ""
    @State private var port = ""
    @State private var isUDP = false
    @State private var run = ToolRun<Components.Schemas.PortTestResult>()

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
                Picker("Protocol", selection: $isUDP) {
                    Text(verbatim: "TCP").tag(false)
                    Text(verbatim: "UDP").tag(true)
                }
                .pickerStyle(.segmented)
                ToolRunButton(
                    title: "Test",
                    isRunning: run.isRunning,
                    isEnabled: !trimmedHost.isEmpty && portNumber != nil,
                    action: start
                )
            } footer: {
                if trimmedHost.isEmpty {
                    Text("Enter a host name or an IP address first.")
                } else if portNumber == nil {
                    Text("Enter a port between 1 and 65535.")
                } else if isUDP {
                    // Worth stating rather than letting the operator read
                    // "open" as proof: a silent UDP port is indistinguishable
                    // from an open one that has nothing to say.
                    Text("UDP has no handshake, so an open port and a silent one can look the same.")
                }
            }

            ToolResultSection(
                run: run, idleMessage: "Enter a host and port to test from the control plane."
            ) { result in
                LabeledContent("State") {
                    Label {
                        Text(verbatim: result.state)
                    } icon: {
                        Image(systemName: symbol(for: result.state))
                    }
                    .foregroundStyle(tint(for: result.state))
                }
                LabeledContent("Target") {
                    // `protocol` is a Swift keyword, so the generator escapes it.
                    Text(verbatim: "\(result.host):\(result.port)/\(result._protocol)")
                        .font(.body.monospaced())
                }
                if let rtt = result.rttMs {
                    LabeledContent("Round trip", value: "\(Int(rtt.rounded())) ms")
                }
                if let error = result.error, !error.isEmpty {
                    Label {
                        Text(verbatim: error)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ToolProvenanceView(ranFrom: result.ranFrom)
            }
        }
        .navigationTitle("Port Test")
        .navigationBarTitleDisplayMode(.inline)
        .dismissableKeyboard()
    }

    private func symbol(for state: String) -> String {
        switch state.lowercased() {
        case "open": "checkmark.circle.fill"
        case "closed", "refused": "xmark.circle.fill"
        default: "questionmark.circle.fill"
        }
    }

    private func tint(for state: String) -> Color {
        switch state.lowercased() {
        case "open": .green
        case "closed", "refused": .red
        default: .orange
        }
    }

    private func start() {
        guard !trimmedHost.isEmpty, let portNumber else { return }
        dismissKeyboard()
        let host = trimmedHost
        let isUDP = isUDP
        Task {
            await run.run {
                let body = Components.Schemas.PortTestRequest(
                    host: host, port: portNumber, _protocol: isUDP ? "udp" : "tcp"
                )
                switch try await session.client.portTestApiV1ToolsPortTestPost(body: .json(body)) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        }
    }
}
