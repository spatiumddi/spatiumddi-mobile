# Security

This app changes nothing yet, but it holds a credential to a system that runs
production DNS and DHCP. The rules below are not aspirations — they are
constraints the code is built to, and several of them are enforced by tests.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it through
[GitHub's private vulnerability reporting](https://github.com/spatiumddi/spatiumddi-mobile/security/advisories/new)
on this repository. If the issue is in the control plane rather than the app,
report it against
[spatiumddi/spatiumddi](https://github.com/spatiumddi/spatiumddi/security/advisories/new)
instead.

Please include what you did, what happened, and what you expected. If you have a
proof of concept, say so — but don't test against anyone's control plane but your
own.

This is a small project run on nights and weekends; expect a human, not an SLA.

---

## What the app guarantees

### 1. The API client is generated, never hand-written

A hand-written model drifts from the server within a release and the drift is
silent — a renamed field simply decodes as absent, and the screen renders as
though the data were empty. For an app whose job is reporting the truth about a
production network, silently wrong is worse than broken.

### 2. Tokens live in the Keychain, gated by biometrics

Never `UserDefaults`, never a plist, never a log line. Keychain items use
`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` with a `.biometryCurrentSet`
access control, so changing the device's biometric enrolment invalidates them.

The gate is enforced **in the token store, not at its call sites**.
`SecAccessControlCreateWithFlags` will mint a `.biometryCurrentSet` policy on a
device with no enrolment — the simulator does exactly this — and the write then
succeeds, storing a token nothing would ever be asked to unlock. The store
therefore refuses to save at all unless biometry is genuinely available.

`Authorization` is redacted in every logging path, through a single helper that
exists so no future logging code can print it by accident.

### 3. No API response data is ever written to disk

No offline cache of subnets, leases, zones or records. Response data lives in
view state for the session and is gone when the app backgrounds.

This is a deliberate trade against convenience. A stale-but-plausible lease table
is worse than an error state, because an operator cannot tell that it is stale —
and acting on it changes production networks.

### 4. Client-side permission gating is UX, not security

The server enforces permissions independently. Hiding a button is a courtesy.

A 403 is surfaced honestly — "you don't have permission to read this" — and never
swallowed into a blank screen, because a blank list is indistinguishable from
"there is nothing here", and those two mean very different things to someone
deciding whether a subnet is free.

### 5. Maintenance mode is a real state

During a change window the control plane returns 503 with `Retry-After`. The app
shows that as what it is, never retries into it automatically, and never
disguises it as a network failure.

### 6. Every write will be confirmed

No destructive action lands on a single tap. (Phase 1 is read-only, so nothing
here writes yet — but the rule is set before the first write ships, not after.)

### 7. Nothing leaves the device

No telemetry, no analytics, no crash reporting — not without an explicit opt-in
that does not currently exist. Operators run this self-hosted and frequently
air-gapped; an app that phones home is a non-starter.

This constraint is why push notifications
([spatiumddi#912](https://github.com/spatiumddi/spatiumddi/issues/912)) are a
genuinely hard design problem rather than a small feature: any relay-based
delivery puts a third party in the path, so the payload must carry nothing
sensitive and the whole channel must be default-off.

### 8. TLS validation is never disabled

There is no `NSAllowsArbitraryLoads`, no "accept all certificates" toggle, and
there will not be one. Such a switch silently downgrades every install, including
the ones that had a perfectly valid certificate.

Self-hosted installs behind a private CA are handled by **trust, not bypass**: the
operator is shown the certificate's SHA-256 fingerprint and subject, confirms it,
and the app pins what they approved. Only three outcomes exist in the trust
delegate — system-valid, matches-an-approved-pin, or refused — and there is no
path that accepts an unvalidated, unapproved certificate.

A changed certificate challenges again rather than silently continuing.

---

## Scope notes for researchers

- **Plaintext HTTP is not supported.** `ServerAddress` refuses to parse it. A
  report that the app "allows HTTP" is not reproducible; a report that it can be
  *made* to speak HTTP very much is.
- **Certificate pinning is per-`host:port`.** `example.com:443` and
  `example.com:8443` are distinct trust entries by design.
- **Tokens used in CI or test runs are considered disclosed.** `xcodebuild` dumps
  its launch environment to the log, so any token passed that way is treated as
  compromised and revoked. This is documented in
  [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Supply chain

- Dependencies are pinned via `Package.resolved` and watched by Dependabot.
- GitHub Actions are pinned by commit SHA where they're third-party.
- Trivy and CodeQL run on every push and pull request.
- The OpenAPI document is committed byte-for-byte from a signed release asset, so
  the generated client can be reproduced and verified against what upstream
  published.
