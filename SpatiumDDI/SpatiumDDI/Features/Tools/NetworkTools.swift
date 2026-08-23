//
//  NetworkTools.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Diagnostics run **from the control plane**, which is the whole point.
///
/// A phone can already ping things itself, and that answer is worth very
/// little: the phone is on Wi-Fi, or a VPN, or a mobile network, and none of
/// those is where the service lives. "Can the *server* resolve this name",
/// "is that port open *from inside*", "what does the resolver actually return"
/// are the questions an operator has while standing somewhere that is not
/// their desk, and until now they needed a laptop to ask any of them.
///
/// Nothing here changes the estate. Wake-on-LAN is the one exception, and what
/// it changes is a power state — so it is the one that confirms.
struct NetworkToolsView: View {
    let session: ControlPlaneSession

    /// Nmap is its own platform module, switched on separately from the rest
    /// of the tools — so its row is gated here rather than the whole section.
    @Environment(FeatureModules.self) private var features

    var body: some View {
        List {
            Section {
                link("Ping", "wave.3.right") {
                    ReachabilityToolView(session: session, tool: .ping)
                }
                link("Traceroute", "point.topleft.down.to.point.bottomright.curvepath") {
                    ReachabilityToolView(session: session, tool: .traceroute)
                }
                link("MTR", "chart.line.uptrend.xyaxis") {
                    ReachabilityToolView(session: session, tool: .mtr)
                }
                link("Port Test", "powerplug") {
                    PortTestToolView(session: session)
                }
                if features.isAvailable("tools.nmap") {
                    link("Nmap", "dot.radiowaves.left.and.right") {
                        NmapView(session: session)
                    }
                }
            } header: {
                Text("Reachability")
            } footer: {
                Text(
                    "Run from the control plane, not from this phone — so the answer is the one that matters."
                )
            }

            Section("Name resolution") {
                link("Dig", "magnifyingglass.circle") {
                    DigToolView(session: session)
                }
                link("Propagation Check", "globe.badge.chevron.backward") {
                    PropagationToolView(session: session)
                }
            }

            Section("Identity") {
                link("TLS Certificate", "lock.shield") {
                    TLSCertToolView(session: session)
                }
                link("WHOIS", "doc.text.magnifyingglass") {
                    WhoisToolView(session: session)
                }
                link("MAC Vendor", "barcode.viewfinder") {
                    MACVendorToolView(session: session)
                }
            }

            Section {
                link("Wake on LAN", "power") {
                    WakeOnLANToolView(session: session)
                }
            } footer: {
                Text(
                    "The only tool here that changes anything, and what it changes is whether a machine is switched on."
                )
            }
        }
        .navigationTitle("Network Tools")
    }

    private func link(
        _ title: LocalizedStringResource, _ symbol: String,
        @ViewBuilder destination: @escaping () -> some View
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
        }
    }
}

// MARK: - Input and verdicts

/// A list of MAC addresses as somebody actually pastes one.
///
/// Separate from the view because the useful version of a vendor lookup is a
/// handful of MACs copied out of a lease table or a switch's ARP output, and
/// those arrive newline-separated, comma-separated, or space-separated
/// depending on where they came from. Refusing to parse the shape somebody
/// pasted is the kind of thing that sends them back to a laptop.
nonisolated enum MACList {
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// What a fetched certificate amounts to, in one word.
///
/// Ordered, and the order is the point: a certificate can be expired *and*
/// self-signed *and* for the wrong name, and reporting the least alarming of
/// those is how somebody talks themselves into ignoring it. Expiry wins,
/// because it is the one that has already broken something.
nonisolated enum CertificateVerdict: Equatable {
    case expired
    case wrongHostname
    case selfSigned
    case valid
    case unusable

    static func of(
        expired: Bool?, hostnameMatches: Bool?, selfSigned: Bool?, ok: Bool
    ) -> CertificateVerdict {
        if expired == true { return .expired }
        if hostnameMatches == false { return .wrongHostname }
        if selfSigned == true { return .selfSigned }
        return ok ? .valid : .unusable
    }

    var label: LocalizedStringResource {
        switch self {
        case .expired: "Expired"
        case .wrongHostname: "Valid, but not for this host name"
        case .selfSigned: "Self-signed"
        case .valid: "Valid"
        case .unusable: "Not usable"
        }
    }

    /// Only a fully valid certificate reads as good news.
    var isGood: Bool { self == .valid }
}

/// What one resolver said during a propagation check.
///
/// The vocabulary is the server's — `ok`, `nxdomain`, `timeout`, `error` — and
/// not the DNS RCODE names it resembles. Assuming `NOERROR` here painted every
/// successful resolver amber, which during a propagation check is exactly the
/// wrong way round: amber is supposed to mean "this one hasn't got it yet".
///
/// `nxdomain` is deliberately *not* red. Mid-propagation it is the expected
/// answer from resolvers that have not caught up, and the whole screen exists
/// to watch those turn green.
nonisolated enum ResolverStatus: Equatable {
    case answered
    case missing
    case timedOut
    case failed
    case other(String)

    init(_ raw: String) {
        switch raw.lowercased() {
        case "ok": self = .answered
        case "nxdomain": self = .missing
        case "timeout": self = .timedOut
        case "error": self = .failed
        default: self = .other(raw)
        }
    }

    var tint: Color {
        switch self {
        case .answered: .green
        case .missing, .timedOut: .orange
        case .failed: .red
        // An unknown word is not evidence of anything, so it is not coloured
        // as though it were.
        case .other: .secondary
        }
    }
}

/// A port, as typed.
nonisolated enum PortNumber {
    static func parse(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            (1...65535).contains(value)
        else { return nil }
        return value
    }
}

// MARK: - Running one tool

/// The state of a single tool run.
///
/// Generic over what the tool returns because the shape differs per tool — a
/// wall of `stdout` for ping, a structured verdict for a port test — while the
/// *states* are identical everywhere: nothing yet, working, an answer, or a
/// reason there is no answer.
@MainActor
@Observable
final class ToolRun<Result> {
    enum Phase {
        case idle
        case running
        case done(Result)
        case failed(FailureMessage)
    }

    private(set) var phase: Phase = .idle

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var result: Result? {
        if case .done(let result) = phase { return result }
        return nil
    }

    var failure: FailureMessage? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Runs `operation`, keeping the previous result on screen until the new
    /// one lands — re-running a ping should not blank the output you were
    /// reading while the next one is in flight.
    func run(_ operation: @escaping () async throws -> Result) async {
        phase = .running
        do {
            phase = .done(try await operation())
        } catch {
            // These are reads with a body, not writes, so nothing here is
            // ever offered as re-sendable.
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                phase = .failed(message)
            }
        }
    }
}

/// The Run button, in the shape every tool screen uses.
struct ToolRunButton: View {
    let title: LocalizedStringResource
    let isRunning: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                if isRunning {
                    ProgressView()
                } else {
                    Text(title)
                }
                Spacer()
            }
        }
        .disabled(!isEnabled || isRunning)
    }
}

/// Whatever the tool printed, shown as the server sent it.
///
/// Monospaced and `verbatim`: this is command output, so it is neither
/// translated nor parsed as Markdown, and its own alignment is load-bearing —
/// a traceroute's columns stop meaning anything in a proportional font.
struct CommandOutputView: View {
    let result: Components.Schemas.CommandResult

    var body: some View {
        if !result.available {
            // The tool is missing from the control plane's image rather than
            // broken. Saying which is the difference between "install it" and
            // "something is wrong".
            Label {
                Text("\(result.tool) isn't installed on this control plane.")
            } icon: {
                Image(systemName: "questionmark.app.dashed")
            }
            .foregroundStyle(.orange)
        } else {
            if let error = result.error, !error.isEmpty {
                Label {
                    Text(verbatim: error)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                }
                .foregroundStyle(.red)
            }

            if result.timedOut == true {
                Label("The command timed out.", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }

            if let stdout = result.stdout, !stdout.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(verbatim: stdout)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if let stderr = result.stderr, !stderr.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(verbatim: stderr)
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            ToolProvenanceView(
                argv: result.argv,
                exitCode: result.exitCode,
                durationMS: result.durationMs,
                ranFrom: result.ranFrom
            )
        }
    }
}

/// What was actually run, where, and how it ended.
///
/// Worth showing rather than hiding: an operator reading unexpected output's
/// first question is what the flags were, and their second is which host it
/// ran from. Both are the difference between believing the result and
/// re-running it on a laptop to check.
struct ToolProvenanceView: View {
    var argv: [String] = []
    var exitCode: Int?
    var durationMS: Double?
    var ranFrom: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !argv.isEmpty {
                Text(verbatim: argv.joined(separator: " "))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let exitCode { Text("exit \(exitCode)") }
                if let durationMS { Text(verbatim: "\(Int(durationMS.rounded())) ms") }
                if let ranFrom, !ranFrom.isEmpty { Text(verbatim: "from \(ranFrom)") }
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

/// The section a tool's answer lands in, with its failure and empty states.
struct ToolResultSection<Result, Content: View>: View {
    let run: ToolRun<Result>
    var idleMessage: LocalizedStringResource
    @ViewBuilder let content: (Result) -> Content

    var body: some View {
        Section("Result") {
            switch run.phase {
            case .idle:
                Text(idleMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Running…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            case .done(let result):
                content(result)
            }
        }
    }
}
