//
//  NmapView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Port scanning, started here and run by the control plane.
///
/// The phone is only the thing that asked: the scan runs on the server, from
/// inside the network, which is both the useful vantage point and the reason
/// this works at all — a phone cannot usefully scan a subnet it is not on.
///
/// **Polled rather than streamed.** The platform offers a live SSE feed and the
/// web console uses it, but a stream dies the moment the app is backgrounded,
/// which on a phone is what happens the moment you put it in your pocket to go
/// and look at the thing you are scanning. Polling picks the answer back up.
///
/// `override_do_not_probe` is not offered here, exactly as in the other tools.
/// A device marked fragile is marked fragile for a reason, and nmap is the
/// tool most likely to prove it.
struct NmapView: View {
    let session: ControlPlaneSession

    @State private var model: NmapModel
    @State private var isStamping = false

    init(session: ControlPlaneSession) {
        self.session = session
        _model = State(initialValue: NmapModel(session: session))
    }

    var body: some View {
        List {
            Section {
                TextField("Target IP or CIDR", text: $model.target)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .font(.body.monospaced())
                Picker("Scan", selection: $model.preset) {
                    ForEach(NmapPreset.offered, id: \.id) { preset in
                        Text(preset.label).tag(preset.id)
                    }
                }
                TextField("Ports (optional, e.g. 22,80,443)", text: $model.portSpec)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .font(.body.monospaced())
                Button {
                    dismissKeyboard()
                    Task { await model.start() }
                } label: {
                    HStack {
                        Spacer()
                        if model.isStarting {
                            ProgressView()
                        } else {
                            Text("Start Scan")
                        }
                        Spacer()
                    }
                }
                .disabled(model.trimmedTarget.isEmpty || model.isStarting || model.isRunning)
            } header: {
                Text("Scan")
            } footer: {
                if model.trimmedTarget.isEmpty {
                    Text("Enter an address or a CIDR range to scan.")
                } else {
                    Text(NmapPreset.description(for: model.preset))
                }
            }

            if let scan = model.scan {
                Section("Result") {
                    NmapScanDetail(scan: scan)
                    if model.isRunning {
                        Button("Cancel Scan", role: .destructive) {
                            Task { await model.cancel() }
                        }
                    } else if NmapStatus(scan.status).didFinish {
                        Button {
                            isStamping = true
                        } label: {
                            Label("Add What It Found to IPAM", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }

            if let failure = model.failure {
                Section("Not scanned") {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Recent scans") {
                LoadStateView(
                    state: model.history,
                    emptyMessage: "No scans have been run on this control plane.",
                    retry: { Task { await model.loadHistory() } }
                ) { scans in
                    ForEach(scans, id: \.id) { scan in
                        Button {
                            model.show(scan)
                        } label: {
                            NmapHistoryRow(scan: scan)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Nmap")
        .dismissableKeyboard()
        .refreshable { await model.loadHistory() }
        .task { await model.loadHistory() }
        // Keyed on the scan being watched: starting another one restarts the
        // poll, and leaving the screen cancels it.
        .task(id: model.pollKey) { await model.pollUntilFinished() }
        .alert("Add discovered hosts to IPAM?", isPresented: $isStamping) {
            Button("Cancel", role: .cancel) {}
            Button("Add") { Task { await model.stampDiscovered() } }
        } message: {
            Text(
                "Every host this scan found answering is created in IPAM, or has its last-seen time updated if it is already there. Addresses outside a known subnet are skipped."
            )
        }
    }
}

/// One scan's outcome, in the order the questions get asked.
private struct NmapScanDetail: View {
    let scan: Components.Schemas.NmapScanRead

    private var status: NmapStatus { NmapStatus(scan.status) }

    var body: some View {
        LabeledContent("Status") {
            Label {
                Text(verbatim: scan.status)
            } icon: {
                Image(systemName: status.symbol)
            }
            .foregroundStyle(status.tint)
        }
        LabeledContent("Target") {
            Text(verbatim: scan.targetIp).font(.body.monospaced())
        }
        if let seconds = scan.durationSeconds {
            LabeledContent("Took", value: "\(Int(seconds.rounded())) s")
        }
        // The parsed result, which is the reason to run this from a phone at
        // all — "what is on that box" as a list you can read one-handed,
        // rather than the wall of text below it.
        if let summary = scan.summary {
            if let hosts = summary.hosts, !hosts.isEmpty {
                ForEach(Array(hosts.enumerated()), id: \.offset) { _, host in
                    NmapHostRow(host: host)
                }
            } else if let ports = summary.ports, !ports.isEmpty {
                // A single-host scan reports its ports at the top level.
                NmapHostRow(
                    host: .init(
                        hostState: summary.hostState, ports: ports
                    )
                )
            } else if let state = summary.hostState, !state.isEmpty {
                LabeledContent("Host") { Text(verbatim: state) }
            }
        }
        if let error = scan.errorMessage, !error.isEmpty {
            Label {
                Text(verbatim: error)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
            }
            .foregroundStyle(.red)
        }
        if let output = scan.rawStdout, !output.isEmpty {
            // nmap's own alignment carries meaning, so this keeps it and
            // scrolls rather than wrapping.
            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        ToolProvenanceView(
            argv: scan.commandLine.map { [$0] } ?? [],
            exitCode: scan.exitCode
        )
    }
}

/// One host the scan found, and what is listening on it.
private struct NmapHostRow: View {
    let host: Components.Schemas.NmapHostResult

    /// Closed and filtered ports are the majority of any scan and none of the
    /// answer. Showing them would bury the two lines that matter.
    private var interesting: [Components.Schemas.NmapPortResult] {
        (host.ports ?? []).filter { $0.state.lowercased().hasPrefix("open") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let address = host.address, !address.isEmpty {
                    Text(verbatim: address).font(.subheadline.monospaced().weight(.semibold))
                }
                if let name = host.hostname, !name.isEmpty {
                    Text(verbatim: name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let state = host.hostState, !state.isEmpty {
                    Badge(
                        text: state,
                        tint: state.lowercased() == "up" ? .green : .secondary
                    )
                }
            }

            if let os = host.os?.name, !os.isEmpty {
                Label {
                    Text(verbatim: os)
                } icon: {
                    Image(systemName: "cpu")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if interesting.isEmpty {
                Text("No open ports found.").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(interesting.enumerated()), id: \.offset) { _, port in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(port.port)/\(port.proto)")
                            .font(.caption.monospaced())
                            .frame(minWidth: 62, alignment: .leading)
                        if let service = port.service, !service.isEmpty {
                            Text(verbatim: service).font(.caption)
                        }
                        // The product and version are what turn "something is
                        // on 22" into "OpenSSH 9.6, which we have patched".
                        if let detail = port.productDescription {
                            Text(verbatim: detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension Components.Schemas.NmapPortResult {
    /// Product, version and any extra the scanner volunteered, as one phrase.
    var productDescription: String? {
        let parts = [product, version, extrainfo].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

private struct NmapHistoryRow: View {
    let scan: Components.Schemas.NmapScanRead

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: scan.targetIp).font(.subheadline.monospaced())
                Spacer()
                Badge(text: scan.status, tint: NmapStatus(scan.status).tint)
            }
            HStack(spacing: 8) {
                Text(verbatim: scan.preset)
                Text(scan.createdAt.formatted(.relative(presentation: .named)))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Vocabulary

/// Where a scan has got to.
///
/// The server's own words. Only `queued` and `running` mean "keep asking";
/// everything else is where it stopped, and the app must not sit polling a
/// scan that already failed.
nonisolated enum NmapStatus: Equatable {
    case queued
    case running
    case finished
    case cancelled
    case failed
    case other(String)

    init(_ raw: String) {
        switch raw.lowercased() {
        case "queued", "pending": self = .queued
        case "running": self = .running
        case "completed", "complete", "done", "finished", "success": self = .finished
        case "cancelled", "canceled": self = .cancelled
        case "failed", "error": self = .failed
        default: self = .other(raw)
        }
    }

    /// Whether the app should keep asking.
    var isInFlight: Bool { self == .queued || self == .running }

    /// Whether there is a result worth acting on.
    var didFinish: Bool { self == .finished }

    var tint: Color {
        switch self {
        case .queued, .running: .orange
        case .finished: .green
        case .failed: .red
        case .cancelled: .secondary
        // An unknown word is not evidence of anything.
        case .other: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "dot.radiowaves.left.and.right"
        case .finished: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "slash.circle"
        case .other: "questionmark.circle"
        }
    }
}

/// The scan shapes worth offering without a keyboard full of nmap flags.
nonisolated enum NmapPreset {
    struct Offered: Identifiable {
        let id: String
        let label: LocalizedStringResource
    }

    /// `custom` is deliberately absent: it exists to carry arbitrary nmap
    /// arguments, and composing those is a desk job.
    static let offered: [Offered] = [
        .init(id: "quick", label: "Quick"),
        .init(id: "subnet_sweep", label: "Subnet sweep"),
        .init(id: "service_version", label: "Service versions"),
        .init(id: "os_fingerprint", label: "OS fingerprint"),
        .init(id: "service_and_os", label: "Services and OS"),
        .init(id: "default_scripts", label: "Default scripts"),
        .init(id: "udp_top1000", label: "UDP top 1000"),
        .init(id: "aggressive", label: "Aggressive"),
    ]

    /// What each one is for, and what it costs — the aggressive ones take
    /// minutes and are noticeable at the far end.
    static func description(for preset: String) -> LocalizedStringResource {
        switch preset {
        case "quick": "The common ports on one host. Fast."
        case "subnet_sweep": "Which addresses in the range answer at all. No port detail."
        case "service_version": "What is listening, and which version of it."
        case "os_fingerprint": "Guesses the operating system from how it replies."
        case "service_and_os": "Both of the above. Slower."
        case "default_scripts": "Runs nmap's default scripts. Noisy at the far end."
        case "udp_top1000": "UDP is slow to scan and easy to miss. Expect minutes."
        case "aggressive": "Everything at once. Slowest, and the most obvious in a log."
        default: "Runs the preset as the control plane defines it."
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class NmapModel {
    var target = ""
    var preset = "quick"
    var portSpec = ""

    private(set) var scan: Components.Schemas.NmapScanRead?
    private(set) var isStarting = false
    private(set) var failure: FailureMessage?
    private(set) var history: LoadState<[Components.Schemas.NmapScanRead]> = .idle

    private let session: ControlPlaneSession

    init(session: ControlPlaneSession) {
        self.session = session
    }

    var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isRunning: Bool {
        guard let scan else { return false }
        return NmapStatus(scan.status).isInFlight
    }

    /// Identifies the scan the poll loop should be watching, so `.task(id:)`
    /// restarts it when a new scan begins and stops once one settles.
    var pollKey: String? { isRunning ? scan?.id : nil }

    func show(_ scan: Components.Schemas.NmapScanRead) {
        self.scan = scan
        failure = nil
    }

    func start() async {
        guard !trimmedTarget.isEmpty else { return }
        isStarting = true
        failure = nil
        defer { isStarting = false }

        let ports = portSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Components.Schemas.NmapScanCreate(
            portSpec: ports.isEmpty ? nil : ports,
            // The document types this as an enum, so an unrecognised preset
            // falls back rather than being sent as a string the server would
            // reject with a 422 nobody can act on.
            preset: .init(rawValue: preset) ?? .quick,
            targetIp: trimmedTarget
        )
        do {
            switch try await session.client.createScanApiV1NmapScansPost(body: .json(body)) {
            case .accepted(let accepted):
                scan = try accepted.body.json
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
        }
    }

    /// Asks again until the scan stops moving.
    ///
    /// Cancelled automatically when the view goes away, because `.task(id:)`
    /// owns it — a poll loop that outlives its screen is a battery leak.
    func pollUntilFinished() async {
        while !Task.isCancelled, let id = scan?.id, isRunning {
            // Two seconds: fast enough that a quick scan feels live, slow
            // enough that a five-minute UDP sweep is not 150 round trips.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await refresh(id)
        }
        // One last read, so the finished row carries its output and summary.
        if let id = scan?.id { await refresh(id) }
        await loadHistory()
    }

    private func refresh(_ id: String) async {
        guard
            case .ok(let ok) = try? await session.client.getScanApiV1NmapScansScanIdGet(
                path: .init(scanId: id)
            ), let updated = try? ok.body.json
        else { return }
        scan = updated
    }

    func cancel() async {
        guard let id = scan?.id else { return }
        failure = nil
        do {
            switch try await session.client.cancelScanApiV1NmapScansScanIdDelete(
                path: .init(scanId: id)
            ) {
            case .noContent: await refresh(id)
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
        }
    }

    /// Creates IPAM rows for the hosts that answered.
    func stampDiscovered() async {
        guard let id = scan?.id else { return }
        failure = nil
        do {
            switch try await session.client
                .stampDiscoveredApiV1NmapScansScanIdStampDiscoveredPost(path: .init(scanId: id))
            {
            case .ok:
                // The counts come back untyped, so rather than guess at them
                // the screen re-reads the scan and lets IPAM speak for itself.
                await refresh(id)
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
        }
    }

    func loadHistory() async {
        if case .idle = history { history = .loading }
        history = await LoadState.fetching {
            switch try await session.client.listScansApiV1NmapScansGet(
                query: .init(page: 1, pageSize: 25)
            ) {
            case .ok(let ok):
                return try ok.body.json.items
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}
