//
//  LookupTools.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// What the control plane's resolver actually returns.
///
/// The question this answers is not "what is the A record" — the DNS section
/// already shows what the zone *says*. It is whether the servers are handing
/// that out, which is a different fact and the one that decides whether a
/// change has really landed.
struct DigToolView: View {
    let session: ControlPlaneSession

    /// The types worth having on a phone keyboard-free. Anything rarer is a
    /// desk job, and the field below takes it anyway.
    private static let types = ["A", "AAAA", "CNAME", "MX", "TXT", "NS", "SOA", "SRV", "PTR", "CAA"]

    @State private var name = ""
    @State private var recordType = "A"
    @State private var server = ""
    @State private var run = ToolRun<Components.Schemas.CommandResult>()

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Name to look up", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(start)
                Picker("Type", selection: $recordType) {
                    ForEach(Self.types, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                TextField("Resolver (optional)", text: $server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                ToolRunButton(
                    title: "Look Up",
                    isRunning: run.isRunning,
                    isEnabled: !trimmedName.isEmpty,
                    action: start
                )
            } footer: {
                if trimmedName.isEmpty {
                    Text("Enter a name to look up first.")
                } else {
                    Text("Leave the resolver empty to ask whatever the control plane itself uses.")
                }
            }

            ToolResultSection(
                run: run, idleMessage: "Enter a name to ask the control plane's resolver."
            ) { result in
                CommandOutputView(result: result)
            }
        }
        .navigationTitle("Dig")
        .navigationBarTitleDisplayMode(.inline)
        .dismissableKeyboard()
    }

    private func start() {
        guard !trimmedName.isEmpty else { return }
        dismissKeyboard()
        let name = trimmedName
        let type = recordType
        let resolver = server.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await run.run {
                let body = Components.Schemas.DigRequest(
                    name: name, recordType: type, server: resolver.isEmpty ? nil : resolver
                )
                switch try await session.client.digApiV1ToolsDigPost(body: .json(body)) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        }
    }
}

/// The same name, asked of several public resolvers at once.
///
/// This is the "has it propagated" screen, and it is the one worth having in a
/// pocket: after a record change, the question is whether the outside world
/// agrees yet, and the honest answer is a list of resolvers that disagree.
struct PropagationToolView: View {
    let session: ControlPlaneSession

    private static let types = ["A", "AAAA", "CNAME", "MX", "TXT", "NS"]

    @State private var name = ""
    @State private var recordType = "A"
    @State private var run = ToolRun<Components.Schemas.PropagationCheckResult>()

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Name to check", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(start)
                Picker("Type", selection: $recordType) {
                    ForEach(Self.types, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                ToolRunButton(
                    title: "Check",
                    isRunning: run.isRunning,
                    isEnabled: !trimmedName.isEmpty,
                    action: start
                )
            } footer: {
                if trimmedName.isEmpty {
                    Text("Enter a name to check first.")
                } else {
                    // Says where the traffic goes: this one leaves the estate.
                    Text("This asks public resolvers, so the name you enter leaves your network.")
                }
            }

            ToolResultSection(
                run: run,
                idleMessage: "Enter a name to ask several public resolvers at once."
            ) { result in
                if result.results.isEmpty {
                    Text("No resolver answered.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(result.results.enumerated()), id: \.offset) { _, row in
                        ResolverRow(row: row)
                    }
                }
            }
        }
        .navigationTitle("Propagation")
        .navigationBarTitleDisplayMode(.inline)
        .dismissableKeyboard()
    }

    private func start() {
        guard !trimmedName.isEmpty else { return }
        dismissKeyboard()
        let name = trimmedName
        let type = recordType
        Task {
            await run.run {
                let body = Components.Schemas.PropagationRequest(name: name, recordType: type)
                switch try await session.client.dnsPropagationApiV1ToolsDnsPropagationPost(
                    body: .json(body)
                ) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        }
    }
}

/// One resolver's answer, with the disagreement made visible.
private struct ResolverRow: View {
    let row: Components.Schemas.ResolverResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: row.resolver)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Badge(text: row.status, tint: ResolverStatus(row.status).tint)
                if let rtt = row.rttMs {
                    Text(verbatim: "\(Int(rtt.rounded())) ms")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let answers = row.answers, !answers.isEmpty {
                Text(verbatim: answers.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else if let error = row.error, !error.isEmpty {
                Text(verbatim: error).font(.caption).foregroundStyle(.orange)
            } else {
                Text("No answer.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Who owns a name or a number.
struct WhoisToolView: View {
    let session: ControlPlaneSession

    @State private var query = ""
    @State private var run = ToolRun<Components.Schemas.CommandResult>()

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Domain, IP or ASN", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(start)
                ToolRunButton(
                    title: "Look Up",
                    isRunning: run.isRunning,
                    isEnabled: !trimmed.isEmpty,
                    action: start
                )
            } footer: {
                if trimmed.isEmpty {
                    Text("Enter a domain, an IP address or an AS number first.")
                } else {
                    Text("WHOIS queries go to a public registry, so this leaves your network.")
                }
            }

            ToolResultSection(run: run, idleMessage: "Enter something to look up in WHOIS.") {
                result in
                CommandOutputView(result: result)
            }
        }
        .navigationTitle("WHOIS")
        .navigationBarTitleDisplayMode(.inline)
        .dismissableKeyboard()
    }

    private func start() {
        guard !trimmed.isEmpty else { return }
        dismissKeyboard()
        let query = trimmed
        Task {
            await run.run {
                switch try await session.client.whoisApiV1ToolsWhoisPost(
                    body: .json(.init(query: query))
                ) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        }
    }
}

/// Whose hardware is that.
///
/// Takes several MACs at once because the useful version of this question is
/// usually a handful pasted out of a lease table, not one typed by hand.
struct MACVendorToolView: View {
    let session: ControlPlaneSession

    @State private var macs = ""
    @State private var run = ToolRun<Components.Schemas.MacVendorResult>()

    private var parsed: [String] { MACList.parse(macs) }

    var body: some View {
        Form {
            Section {
                TextField("MAC addresses", text: $macs, axis: .vertical)
                    .lineLimit(3...8)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                ToolRunButton(
                    title: "Look Up",
                    isRunning: run.isRunning,
                    isEnabled: !parsed.isEmpty,
                    action: start
                )
            } footer: {
                if parsed.isEmpty {
                    Text("Enter at least one MAC address.")
                } else {
                    Text("One per line, or separated by commas. \(parsed.count) so far.")
                }
            }

            ToolResultSection(run: run, idleMessage: "Paste MAC addresses to name their vendors.") {
                result in
                if !result.ouiEnabled {
                    // The lookup table is an opt-in download on the platform.
                    // Without it every answer would be blank for a reason that
                    // has nothing to do with the MACs entered.
                    Label(
                        "OUI vendor lookup is switched off on this control plane.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                ForEach(Array(result.entries.enumerated()), id: \.offset) { _, entry in
                    LabeledContent {
                        if let vendor = entry.vendor, !vendor.isEmpty {
                            Text(verbatim: vendor)
                        } else {
                            Text("Unknown").foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: entry.mac).font(.body.monospaced())
                            if entry.isVoipPhone == true { Badge(localised: "VoIP") }
                        }
                    }
                }
            }
        }
        .navigationTitle("MAC Vendor")
        .navigationBarTitleDisplayMode(.inline)
        .dismissableKeyboard()
    }

    private func start() {
        let macs = parsed
        guard !macs.isEmpty else { return }
        dismissKeyboard()
        Task {
            await run.run {
                switch try await session.client.macVendorApiV1ToolsMacVendorPost(
                    body: .json(.init(macs: macs))
                ) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        }
    }
}
