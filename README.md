<h1 align="center">SpatiumDDI Mobile</h1>

<p align="center">
  <strong>Your DNS, DHCP and IPAM estate, on the phone in your pocket.</strong><br/>
  A native iOS client for <a href="https://github.com/spatiumddi/spatiumddi">SpatiumDDI</a> — built for the operator who is away from the console.
</p>

<p align="center">
  <a href="https://github.com/spatiumddi/spatiumddi-mobile/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/spatiumddi/spatiumddi-mobile/ci.yml?branch=main&label=CI" alt="CI"/></a>
  <a href="https://github.com/spatiumddi/spatiumddi-mobile/actions/workflows/security.yml"><img src="https://img.shields.io/github/actions/workflow/status/spatiumddi/spatiumddi-mobile/security.yml?branch=main&label=security" alt="Security"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="License"/></a>
  <img src="https://img.shields.io/badge/platform-iOS%2018%2B%20%C2%B7%20iPadOS-lightgrey" alt="Platform"/>
  <img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift 6"/>
  <img src="https://img.shields.io/badge/status-phase%201-blue" alt="Status"/>
</p>

---

> **Phase 1, and honest about it.** Everything below that says it works has been
> run against a real control plane. Nothing in this app writes to your network
> yet — it is a read-only client by design, not by omission. See
> [Roadmap](#roadmap).

---

## What this is

The web console is where you *do* DDI work. This is where you *check* it.

Every screen here answers a question you'd otherwise need a laptop for:

- Did that change actually land, or is the daemon still serving the old config?
- Is the DHCP pool that page-out was about actually exhausted?
- What is `10.40.12.68`, and who has had it before?
- Is anything on fire right now?

It talks to a SpatiumDDI control plane over its public REST API and contains no
server-side code. **This repo is a client of a contract it does not own** — the
platform, the API and the roadmap all live in
[spatiumddi/spatiumddi](https://github.com/spatiumddi/spatiumddi).

## What works today

| Surface | What you get |
|---|---|
| **Overview** | Platform health per component, maintenance/demo banners, server version and update check, unresolved alerts by severity, estate counts, and a size-weighted utilisation figure with the busiest subnets |
| **Alerts** | Every alert event, most-severe first, filterable by severity and unresolved-only |
| **IPAM** | The full tree — space → block → subnet → address — with utilisation at every level, and a per-address detail screen covering identity, fingerprinted device, last-seen signal and the DNS/DHCP objects linked to it |
| **DNS** | Group → zone → record, with SOA facts, DNSSEC state and serial per zone, and record filtering by type or substring |
| **DHCP** | Server health and HA state, a live ACK/NAK traffic chart, leases with fingerprinted device class, and scopes with their pools and reservations |
| **Search** | Global search across 16 resource types, grouped by kind, ranked server-side |
| **Connect** | HTTPS-only, with an explicit certificate-trust flow for the private CAs self-hosted installs actually use |
| **Sign in** | Per-device `sddi_` API token, by paste or by scanning the enrolment QR code, stored in the Keychain behind Face ID / Touch ID |

Navigation is a grouped sidebar — **Monitor / Estate / Tools** — which is a real
sidebar on iPad and collapses to a pushed list on iPhone.

## Roadmap

Phasing follows [spatiumddi#884](https://github.com/spatiumddi/spatiumddi/issues/884).
Feature work is filed **upstream**, not on this tracker.

### Phase 1 — read-mostly ✅

Sign-in, dashboard and health, global search, IPAM browse, DNS zone/record view,
DHCP scope/lease view, alert list. Plus the native niceties: pull-to-refresh,
biometric unlock, QR enrolment.

### Phase 2 — a small set of writes

Acknowledge and resolve alerts, approve change requests, allocate the next free
IP, toggle maintenance mode. Approvals-on-the-go is the best mobile write story
there is; the rest of the platform's surface stays desktop work.

Every write will be confirmed. No destructive action lands on a single tap — this
is an app for changing production DNS and DHCP from a phone, one-handed, possibly
on a train.

### Phase 3 — push notifications 🔗 [spatiumddi#912](https://github.com/spatiumddi/spatiumddi/issues/912)

**This is the feature that makes the rest of the app worth having.** An alert list
you have to remember to open is a dashboard. The operator this app is for is the
one who is *away* — and for them the gap between "DHCP pool exhausted" arriving
at 02:00 and being found at 09:00 is the whole value proposition.

Blocked on upstream work that does not exist yet, specified in
[spatiumddi#912](https://github.com/spatiumddi/spatiumddi/issues/912):

- a **device registry** — `(user, device token, platform, build)`, so the control
  plane knows where to send
- an **APNs/FCM delivery channel** in the alert engine, alongside the SMTP,
  syslog and webhook destinations it already has

The genuinely hard part is credentials: a self-hosted control plane cannot mint
an APNs token for an App Store build it does not publish. The options — operator-
supplied credentials, a project-run relay, or both — are laid out in the issue.
Whichever wins has to stay default-off and send an opaque payload, because alert
text names internal hostnames and subnets, and this app does not leak those.

### Phase 4 — Android

Kotlin native vs. KMP vs. React Native is a Phase 4 call, decided then, on
evidence. Deliberately not committed to now.

## Requirements

- **iOS / iPadOS 18** or later
- **Xcode 16** or later (Swift 6 language mode)
- A **SpatiumDDI control plane** at `2026.08.22-1` or newer, reachable over HTTPS

The minimum server version is not arbitrary: it is the release the API client was
generated from, and therefore the only contract this build has actually been
compiled against. The app checks it at sign-in and tells you plainly if the
server is older — or if it reports a development version that cannot be compared
at all.

## Getting started

```bash
git clone https://github.com/spatiumddi/spatiumddi-mobile.git
cd spatiumddi-mobile
open SpatiumDDI/SpatiumDDI.xcodeproj
```

Build and run. Then, in the app:

1. **Connect** — enter your control plane's host name (add `:port` if it isn't
   443). HTTPS only; see [Self-hosted reality](#self-hosted-reality).
2. **Trust the certificate**, if it's behind a private CA — you'll be shown the
   SHA-256 fingerprint and subject to check against what your CA actually issued.
3. **Sign in** with a per-device API token. Mint one in the web console under
   **API Tokens**, then either paste it or scan the enrolment QR code.

For working on the app itself — the stub control plane, the test tiers, how to
re-pin the API client — see **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**. For
getting a build onto a phone, including what TestFlight requires, see
**[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)**.

## Self-hosted reality

Your control plane is probably not a public host with a public CA certificate.
It's `https://ddi.internal.example` behind a private CA, or an appliance whose
internal CA is a self-signed root generated at first boot. App Transport Security
rejects both by default.

The app's answer is **trust, never bypass**: you are shown the certificate's
fingerprint and subject, you confirm it, and the app pins what you approved. From
then on that server — and only that server — is trusted, and a changed
certificate challenges you again.

There is no "accept all certificates" toggle and there never will be. It would
silently downgrade every install, including the ones that had a perfectly good
certificate. Non-standard ports and IP-literal hosts with no name at all are
supported; plaintext HTTP is not.

## Security posture

The rules this app is built to, in full, are in
**[SECURITY.md](SECURITY.md)**. The short version:

- **Tokens live in the Keychain**, gated by biometrics, and are redacted from
  every logging path.
- **Nothing is written to disk.** No offline cache of subnets, leases, zones or
  records — a stale-but-plausible lease table is worse than an error, because you
  cannot tell it is stale, and acting on it changes production networks.
- **Permission gating is UX, not security.** The server enforces independently. A
  403 is shown honestly rather than swallowed into a blank screen.
- **Maintenance mode is a real state.** During a change window the app tells you
  so, and never retries into it or dresses it up as a network failure.
- **No telemetry, analytics or crash reporting leaves the device.** Operators run
  this self-hosted and frequently air-gapped.

## Architecture

A short tour is in **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — the layers,
the generated API client, the trust and token flows, and the load-state pattern
every screen shares.

The one thing worth knowing up front: **the API client is generated, never
hand-written.** `Packages/SpatiumAPI/Sources/SpatiumAPI/openapi.json` is the
release asset from a pinned platform release, committed byte-for-byte so it can
be verified against the published artefact. A hand-written `Codable` struct drifts
from the server within one release, and the drift is silent.

## Where to file things

| What | Where |
|---|---|
| Feature requests, roadmap, API questions | [spatiumddi/spatiumddi](https://github.com/spatiumddi/spatiumddi/issues) |
| App bugs — layout, navigation, crashes | [this tracker](https://github.com/spatiumddi/spatiumddi-mobile/issues) |
| Security vulnerabilities | See [SECURITY.md](SECURITY.md) |

Splitting a roadmap across two trackers is how items get lost. Feature work goes
upstream.

## Licence

Apache 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
