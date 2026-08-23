//
//  LoadStateTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

@Suite("Load state")
@MainActor
struct LoadStateTests {
    /// The message as an operator would read it.
    ///
    /// `LocalizedStringResource` has no `contains`, and that is the point — it
    /// is a key plus arguments, not text, until something resolves it. These
    /// tests assert on the resolved English because that is what ships today.
    private func text(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
    }

    private func describe<Value>(_ state: LoadState<Value>) -> String {
        switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded: "loaded"
        case .failed(let message): "failed(\(String(localized: message)))"
        }
    }

    @Test("A successful fetch loads")
    func loads() async {
        let state = await LoadState<Int>.fetching { 42 }
        guard case .loaded(let value) = state else {
            Issue.record("expected .loaded, got \(describe(state))")
            return
        }
        #expect(value == 42)
    }

    @Test("A thrown status becomes a message an operator can act on")
    func statusBecomesMessage() async {
        let state = await LoadState<Int>.fetching { throw APIStatusError(status: 403) }
        guard case .failed(let message) = state else {
            Issue.record("expected .failed, got \(describe(state))")
            return
        }
        #expect(text(message).contains("permission"))
    }

    @Test("A maintenance window is not reported as a network failure")
    func maintenanceIsItsOwnMessage() async {
        let state = await LoadState<Int>.fetching { throw APIStatusError(status: 503) }
        guard case .failed(let message) = state else {
            Issue.record("expected .failed, got \(describe(state))")
            return
        }
        #expect(text(message).contains("change window"))
    }

    /// The bug this guards against: cancellation arriving as `URLError.cancelled`
    /// rather than `CancellationError`.
    ///
    /// By the time a `.task` is cancelled the request is inside URLSession, so
    /// what comes back is a `URLError` — which a `catch is CancellationError`
    /// misses entirely, flashing the word "cancelled" as a failure over a screen
    /// the operator has already navigated away from.
    @Test("A cancelled fetch reports no state, even when URLSession calls it an error")
    func cancellationIsNotAFailure() async {
        let task = Task { @MainActor in
            await LoadState<Int>.fetching {
                // Spin until cancellation actually lands, so the test does not
                // race the closure, then fail the way URLSession really does.
                while !Task.isCancelled { await Task.yield() }
                throw URLError(.cancelled)
            }
        }
        task.cancel()
        let state = await task.value
        guard case .idle = state else {
            Issue.record("a cancelled fetch should leave no state, got \(describe(state))")
            return
        }
    }

    @Test("A genuine transport failure is still reported")
    func transportFailureIsReported() async {
        let state = await LoadState<Int>.fetching { throw URLError(.timedOut) }
        guard case .failed(let message) = state else {
            Issue.record("expected .failed, got \(describe(state))")
            return
        }
        #expect(text(message).contains("didn't respond"))
    }
}

@Suite("Feature-module errors")
struct FeatureModuleErrorTests {
    private func text(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    /// The platform answers 404 from every endpoint of a disabled module, with
    /// the module named in the body. Reporting the generic 404 message —
    /// "it may have been deleted" — tells an operator their data is gone, which
    /// is both wrong and the kind of wrong that starts an incident.
    @Test(
        "A disabled module is named, not reported as a deletion",
        arguments: [
            ("Feature 'network.vrf' is disabled.", "network.vrf"),
            ("Feature 'governance.approvals' is disabled.", "governance.approvals"),
            ("Feature 'security.tls_certs' is disabled.", "security.tls_certs"),
        ]
    )
    func namesTheModule(detail: String, module: String) {
        let error = APIStatusError(status: 404, detail: detail)
        #expect(error.disabledFeatureModule == module)

        let message = text(APIErrorMessage.describe(error))
        #expect(message.contains(module))
        #expect(!message.contains("deleted"), "a disabled module is not a deletion")
    }

    @Test("A genuine 404 still reads as one")
    func genuineNotFound() {
        let error = APIStatusError(status: 404, detail: "Not Found")
        #expect(error.disabledFeatureModule == nil)
        #expect(text(APIErrorMessage.describe(error)).contains("Not Found"))
    }

    @Test("A 404 with no body falls back to the generic wording")
    func bodilessNotFound() {
        let error = APIStatusError(status: 404)
        #expect(error.disabledFeatureModule == nil)
        #expect(text(APIErrorMessage.describe(error)).contains("deleted"))
    }

    // The gate fails open: a non-admin cannot read /admin/feature-modules, and
    // hiding half the app because a permission check failed would be worse than
    // letting each screen report its own 404.
    @Test("An unknown module list hides nothing")
    @MainActor
    func unknownListHidesNothing() {
        let modules = FeatureModules()
        #expect(modules.isAvailable("network.vrf"))
        #expect(modules.isAvailable(nil))
    }
}

@Suite("Cancellation is never shown raw")
struct CancellationMessageTests {
    private func text(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    /// This exact string reached a screen: "The operation couldn't be completed.
    /// (Swift.CancellationError error 1.)" on the IPAM list, because that view
    /// still had its own `catch` instead of going through `LoadState.fetching`.
    /// Swift's own error text is never something to put in front of an operator.
    @Test("A CancellationError never renders as Swift's own description")
    func cancellationIsNotRaw() {
        let message = text(APIErrorMessage.describe(CancellationError()))
        #expect(!message.contains("CancellationError"))
        #expect(!message.contains("couldn't be completed"))
        #expect(message == "The request was cancelled.")
    }

    @Test("A cancelled URL request is not raw either")
    func urlCancellationIsNotRaw() {
        let message = text(APIErrorMessage.describe(URLError(.cancelled)))
        #expect(!message.contains("NSURLError"))
        #expect(message.contains("cancelled"))
    }
}
