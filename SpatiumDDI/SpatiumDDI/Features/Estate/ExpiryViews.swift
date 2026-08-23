//
//  ExpiryViews.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Registered domains, soonest to expire first.
///
/// A lapsed domain takes DNS with it, and the warning arrives by email to
/// whoever registered it years ago. Sorting by deadline rather than by name is
/// the whole point of putting this on a phone.
struct DomainsView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.DomainRead]> = .idle
    @State private var total = 0
    @State private var query = ""

    private var visible: [Components.Schemas.DomainRead] {
        guard case .loaded(let domains) = state else { return [] }
        guard !query.isEmpty else { return domains }
        return domains.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.registrar ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "No domains are tracked.", retry: load) { _ in
                if visible.isEmpty {
                    NoMatchesView(query: query, filterDescription: "No domain matches this filter.")
                } else {
                    ForEach(visible, id: \.id) { domain in
                        NavigationLink {
                            DomainDetailView(domain: domain)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(domain.name).font(.body.monospaced()).lineLimit(1)
                                    Spacer(minLength: 4)
                                    ExpiryBadge(date: domain.expiresAt)
                                }
                                HStack(spacing: 6) {
                                    if let registrar = domain.registrar, !registrar.isEmpty {
                                        Text(registrar).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if domain.dnssecSigned { Badge(localised: "DNSSEC", tint: .green) }
                                    // Drift means the registrar's nameservers no
                                    // longer match what this platform expects —
                                    // which is how a delegation quietly breaks.
                                    if domain.nameserverDrift { Badge(localised: "NS drift", tint: .red) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Domains")
        .searchable(text: $query, prompt: "Filter domains")
        .dismissableKeyboard()
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.listDomainsApiV1DomainsGet(
                query: .init(page: 1, pageSize: 200)
            )
            switch response {
            case .ok(let ok):
                let page = try ok.body.json
                total = page.total
                // Nil expiry sorts last: an untracked deadline is not urgent,
                // it is unknown, and putting it top would bury the real ones.
                return page.items.sorted {
                    ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
                }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

struct DomainDetailView: View {
    let domain: Components.Schemas.DomainRead

    var body: some View {
        List {
            Section {
                LabeledContent("Domain") {
                    Text(domain.name).font(.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Expires") { ExpiryBadge(date: domain.expiresAt) }
                if let expires = domain.expiresAt {
                    LabeledContent("Expiry date", value: expires.formatted(date: .long, time: .omitted))
                }
                if let registrar = domain.registrar, !registrar.isEmpty {
                    LabeledContent("Registrar", value: registrar)
                }
                if let org = domain.registrantOrg, !org.isEmpty {
                    LabeledContent("Registrant", value: org)
                }
                LabeledContent("DNSSEC", value: domain.dnssecSigned ? "Signed" : "Not signed")
            }

            Section {
                if domain.nameserverDrift {
                    Label(
                        "The registrar's nameservers don't match what's expected here.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)
                }
                if !domain.expectedNameservers.isEmpty {
                    LabeledContent("Expected", value: domain.expectedNameservers.joined(separator: "\n"))
                }
                if !domain.actualNameservers.isEmpty {
                    LabeledContent("Actual", value: domain.actualNameservers.joined(separator: "\n"))
                }
            } header: {
                Text("Nameservers")
            }

            Section("Checks") {
                LabeledContent("WHOIS state", value: domain.whoisState)
                LabeledContent("Last checked", value: Date.relativeOrNever(domain.whoisLastCheckedAt))
                if let renewed = domain.lastRenewedAt {
                    LabeledContent(
                        "Last renewed", value: renewed.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
        .navigationTitle(domain.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// TLS certificates the platform is watching, soonest to expire first.
struct CertificatesView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.TLSCertTargetRead]> = .idle
    @State private var query = ""

    private var visible: [Components.Schemas.TLSCertTargetRead] {
        guard case .loaded(let targets) = state else { return [] }
        guard !query.isEmpty else { return targets }
        return targets.filter {
            $0.host.localizedCaseInsensitiveContains(query)
                || ($0.subjectCn ?? "").localizedCaseInsensitiveContains(query)
                || ($0.issuerCn ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "No certificates are being watched.", retry: load) {
                _ in
                if visible.isEmpty {
                    NoMatchesView(query: query, filterDescription: "No certificate matches this filter.")
                } else {
                    ForEach(visible, id: \.id) { target in
                        NavigationLink {
                            CertificateDetailView(target: target)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(target.host):\(target.port)")
                                        .font(.body.monospaced()).lineLimit(1)
                                    Spacer(minLength: 4)
                                    ExpiryBadge(date: target.notAfter)
                                }
                                if let issuer = target.issuerCn, !issuer.isEmpty {
                                    Text(issuer).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                HStack(spacing: 6) {
                                    Badge(text: target.state, tint: StateTint.forChangeRequest(target.state))
                                    if target.selfSigned == true {
                                        Badge(localised: "self-signed", tint: .orange)
                                    }
                                    if target.chainValid == false {
                                        Badge(localised: "chain invalid", tint: .red)
                                    }
                                    if !target.enabled { Badge(localised: "disabled") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Certificates")
        .searchable(text: $query, prompt: "Filter by host or issuer")
        .dismissableKeyboard()
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.listTargetsApiV1TlsCertsGet(
                query: .init(limit: 200)
            )
            switch response {
            case .ok(let ok):
                return try ok.body.json.items.sorted {
                    ($0.notAfter ?? .distantFuture) < ($1.notAfter ?? .distantFuture)
                }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

struct CertificateDetailView: View {
    let target: Components.Schemas.TLSCertTargetRead

    var body: some View {
        List {
            Section {
                LabeledContent("Host") {
                    Text("\(target.host):\(target.port)").font(.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Expires") { ExpiryBadge(date: target.notAfter) }
                if let notAfter = target.notAfter {
                    LabeledContent("Not after", value: notAfter.formatted(date: .long, time: .shortened))
                }
                if let notBefore = target.notBefore {
                    LabeledContent("Not before", value: notBefore.formatted(date: .long, time: .shortened))
                }
                LabeledContent("State") { StatusLabel(status: target.state) }
            }

            Section("Certificate") {
                if let subject = target.subjectCn, !subject.isEmpty {
                    LabeledContent("Subject", value: subject)
                }
                if let issuer = target.issuerCn, !issuer.isEmpty {
                    LabeledContent("Issuer", value: issuer)
                }
                if let algo = target.keyAlgo {
                    LabeledContent("Key", value: "\(algo) \(target.keySize.map(String.init) ?? "")")
                }
                if let sig = target.sigAlgo, !sig.isEmpty {
                    LabeledContent("Signature", value: sig)
                }
                if let serial = target.serial, !serial.isEmpty {
                    LabeledContent("Serial") {
                        Text(serial).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let fingerprint = target.fingerprintSha256, !fingerprint.isEmpty {
                    LabeledContent("SHA-256 Fingerprint") {
                        Text(fingerprint).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }

            if !target.sansJson.isEmpty {
                Section("Subject alternative names") {
                    ForEach(target.sansJson, id: \.self) { san in
                        Text(san).font(.caption.monospaced())
                    }
                }
            }

            Section("Chain") {
                if let valid = target.chainValid {
                    LabeledContent("Valid", value: valid ? "Yes" : "No")
                }
                if let depth = target.chainDepth {
                    LabeledContent("Depth", value: String(depth))
                }
                if let error = target.chainError, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Probe") {
                LabeledContent("Last checked", value: Date.relativeOrNever(target.lastCheckedAt))
                if target.consecutiveFailures > 0 {
                    LabeledContent("Consecutive failures", value: String(target.consecutiveFailures))
                        .foregroundStyle(.red)
                }
                if let error = target.lastError, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                LabeledContent("Source", value: target.source)
            }
        }
        .navigationTitle(target.host)
        .navigationBarTitleDisplayMode(.inline)
    }
}
