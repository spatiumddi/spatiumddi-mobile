# Development

Building, testing and changing the app. For how it's structured and why, see
[ARCHITECTURE.md](ARCHITECTURE.md).

---

## Prerequisites

- **macOS** with **Xcode 16** or later (Swift 6 language mode)
- An iOS 18+ simulator, or a device in developer mode
- `gh` for release assets and issues (optional)
- Python 3 for the helper scripts (ships with macOS)

```bash
git clone https://github.com/spatiumddi/spatiumddi-mobile.git
cd spatiumddi-mobile
open SpatiumDDI/SpatiumDDI.xcodeproj
```

The project uses Xcode's file-system-synchronized groups, so **a new `.swift`
file anywhere under `SpatiumDDI/SpatiumDDI/` is compiled automatically** — no
project-file edit, and no merge conflict in `project.pbxproj`.

## Building from the command line

```bash
xcodebuild -project SpatiumDDI/SpatiumDDI.xcodeproj \
           -scheme SpatiumDDI \
           -destination 'generic/platform=iOS Simulator' \
           -skipPackagePluginValidation \
           build
```

`-skipPackagePluginValidation` is not optional. The OpenAPI generator runs as a
build-tool plugin, and without the flag a non-interactive build blocks waiting
for plugin approval that nobody is there to give. CI passes it; so should you.
(Xcode's GUI asks once and remembers, which is exactly why forgetting the flag
locally goes unnoticed until CI hangs.)

---

## The stub control plane

Most tests need a server that speaks TLS with a certificate the system won't
validate — the situation every real self-hosted install puts the app in.

```bash
./scripts/dev-control-plane.sh start   # two instances: healthy + in maintenance
./scripts/dev-control-plane.sh stop
./scripts/dev-control-plane.sh test    # start, run the suite, stop
```

It serves `/health/platform` over TLS on `localhost:8443` (healthy) and
`localhost:8444` (permanently in a change window), with a self-signed
certificate generated on first run into `.dev-control-plane/` (git-ignored).

It binds **dual-stack** deliberately. An IPv4-only stub looks fine locally,
because macOS falls back — but `localhost` resolves to `::1` first, and on a CI
runner with no fallback the connection hangs until it times out and the trust
test fails with a misleading error.

### Driving the app against a real HTTP lab

The app is HTTPS-only. If your lab control plane speaks plaintext, terminate TLS
in front of it with the same dev certificate:

```bash
./scripts/dev-control-plane.sh proxy http://ddi.lab.internal:8077
```

---

## Tests

Four tiers, with different requirements. A full run against a live control plane
is 92 tests, all passing; tiers 3 and 4 skip when no lab is configured, so a
contributor without one still gets a green, meaningful run.

### 1. Unit tests — no server needed

Pure logic: address parsing, version comparison, severity mapping, TTL
formatting, health-payload parsing, the weighted-utilisation arithmetic, the
session state machine, redaction.

```bash
./scripts/dev-control-plane.sh test
```

### 2. Trust-flow tests — need the stub

Certificate challenge, pinning, maintenance detection. **They skip silently
without the stub**, which means a run can look green while the security-critical
assertions never executed. `dev-control-plane.sh test` exists so that doesn't
happen by accident.

### 3. Contract tests — need a live control plane

The ones that earn their keep. A compile proves the generated types exist; it
proves nothing about whether the server fills the fields the screens read. Both
bugs this tier has caught were of that kind — dropped nullable fields, and
microsecond timestamps the decoder rejected.

```bash
export TEST_RUNNER_SPATIUM_LIVE_HOST='ddi.example.com'
export TEST_RUNNER_SPATIUM_LIVE_TOKEN='sddi_…'

xcodebuild test -project SpatiumDDI/SpatiumDDI.xcodeproj -scheme SpatiumDDI \
  -destination "$(./scripts/pick-simulator.py)" \
  -skipPackagePluginValidation \
  -only-testing:SpatiumDDITests
```

They skip when those variables are unset, so they never block a contributor
without a lab.

> **Mint a short-lived token, and revoke it when you're done.** `xcodebuild`
> dumps the launch environment into its log, so a token passed this way ends up
> in plaintext on disk. Treat any token used this way as disclosed.

### 4. Screenshot / end-to-end — live server, and produces store assets

`ScreenshotUITests` drives the whole app against a real control plane and
captures every screen. It's the only test that proves a tab *renders* rather than
merely decodes, and it's how App Store screenshots get made — from the app
actually running, not a mockup.

```bash
export TEST_RUNNER_SPATIUM_LIVE_HOST='ddi.example.com'
export TEST_RUNNER_SPATIUM_LIVE_TOKEN='sddi_…'
export TEST_RUNNER_SPATIUM_SHOT_DIR='/tmp/shots'

xcodebuild test … -only-testing:SpatiumDDIUITests/ScreenshotUITests
```

The simulator needs a biometric enrolment (**Features → Face ID → Enrolled**), or
the token store refuses to save — which is the security rule working, not a bug.

> **Known flake:** the XCUITest runner app intermittently fails to launch
> (`Simulator device failed to launch …xctrunner`). It is a runner-bootstrap
> problem, not a test failure — retry, or run it from Xcode. This is also why UI
> tests run only on `main` in CI and not on pull requests.

---

## Formatting

CI lints strictly; fix locally before pushing.

```bash
xcrun swift-format format --in-place --recursive \
  SpatiumDDI/SpatiumDDI SpatiumDDI/SpatiumDDITests SpatiumDDI/SpatiumDDIUITests

xcrun swift-format lint --recursive --strict \
  SpatiumDDI/SpatiumDDI SpatiumDDI/SpatiumDDITests SpatiumDDI/SpatiumDDIUITests
```

---

## Re-pinning the API client

When a new platform release lands:

```bash
gh release download <TAG> --repo spatiumddi/spatiumddi --pattern openapi.json \
  --output Packages/SpatiumAPI/Sources/SpatiumAPI/openapi.json

shasum -a 256 Packages/SpatiumAPI/Sources/SpatiumAPI/openapi.json
```

Then, in `Packages/SpatiumAPI/Sources/SpatiumAPI/openapi-generator-config.yaml`,
update the release tag and checksum in the header comment. And in
`SpatiumDDI/SpatiumDDI/Networking/ServerVersion.swift`, update
`SupportedServer.minimum` to match — **the minimum supported server is the release
the client was generated from**, and letting those two drift apart is how the app
starts claiming a compatibility nobody verified.

Rebuild, then run the contract tests against a live server on that release. A
successful compile is not evidence the contract still holds.

### Adding a screen

Add its paths to the `filter.paths` list in the same config file first — the
document describes 842 paths and only the filtered subset is generated, so the
operation you want won't exist until you list it.

Find the generated names with:

```bash
cd Packages/SpatiumAPI && swift build
grep -oE 'public func [a-zA-Z0-9_]+' \
  .build/plugins/outputs/spatiumapi/SpatiumAPI/destination/OpenAPIGenerator/GeneratedSources/Client.swift
```

---

## Running on a device

1. Xcode → **Signing & Capabilities** → select your team.
2. Plug in the device, enable **Developer Mode** on it (Settings → Privacy &
   Security), and trust the Mac.
3. Select it as the run destination and build.

From the command line, first registration needs:

```bash
xcodebuild -allowProvisioningUpdates -allowProvisioningDeviceRegistration …
```

A personal team allows a small number of devices and the provisioning profile
expires after seven days — that's Apple's limit, not a project one.

---

## CI

Two workflows, both on push to `main` and on pull requests.

| Workflow | Job | Runs on |
|---|---|---|
| `ci.yml` | `swift-format` lint | always |
| | Build & test (unit + trust, against the stub) | always |
| | UI tests | **`main` only**, with retry |
| `security.yml` | Trivy (SHA-pinned) | always |
| | CodeQL | always |

UI tests are kept off the pull-request path on purpose: the runner app's
bootstrap isn't dependable on a hosted machine, and a run in which all unit tests
passed was once failed by the runner being killed before it could connect. A
flake shouldn't block a review.

`scripts/pick-simulator.py` chooses a device that actually exists on the runner,
because the simulator line-up changes with the Xcode image and a pinned model
name eventually stops resolving.

---

## Conventions

- **Branch per issue**, named for the upstream issue where one exists —
  `issue-884-signin`.
- **Never push to `main`, and never open a PR without being asked.** Pushing a
  branch on request is fine; opening a PR is a separate step.
- **No scratch files in the repo tree.** Check `git status --short` before
  committing; never blind `git add -A`.
- **Versioning:** semver marketing version, monotonic build number. This repo
  does *not* follow the platform's CalVer — App Store Connect won't accept it.
- **Screenshots and store metadata** live in the repo. Signing secrets and API
  keys never do — those are Actions secrets.
