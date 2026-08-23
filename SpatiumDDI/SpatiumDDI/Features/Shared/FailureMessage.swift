//
//  FailureMessage.swift
//  SpatiumDDI
//

import Foundation
import SwiftUI

/// Why something failed, in a form that can be shown safely.
///
/// The distinction is not cosmetic. This app's own words are translatable and
/// belong in the string catalogue; the control plane's words are **untrusted
/// input** and must be rendered exactly as sent, through a path that neither
/// parses them nor looks them up.
///
/// Both hazards are real and were both live before this type existed:
///
/// - `Text` parses Markdown for a localised value, so a `detail` of
///   `[Contact support](https://phish.example)` renders as a *tappable link*
///   inside the app's own error banner — a phishing surface in an app holding a
///   Keychain token, reachable by anyone who can MITM an HTTP lab install or
///   compromise a control plane. It also silently mangles honest text:
///   ``Zone `example.com` is locked`` loses its backticks.
/// - `LocalizedStringResource(stringLiteral:)` sets the resource's **key**, so
///   the server's text is looked up in this app's catalogue. A server saying
///   `Access` would render whatever the app's own "Access" label translates to
///   — the opposite of showing a 403 honestly.
nonisolated enum FailureMessage: Equatable, Sendable {
    /// This app's own wording. Translatable.
    case app(LocalizedStringResource)
    /// The control plane's wording, shown verbatim and never interpreted.
    case server(String)
}

extension Text {
    /// Renders a failure the way its origin requires.
    ///
    /// `Text(verbatim:)` for server text is the whole point: it neither parses
    /// Markdown nor consults the catalogue.
    init(_ message: FailureMessage) {
        switch message {
        case .app(let resource): self.init(resource)
        case .server(let text): self.init(verbatim: text)
        }
    }
}

extension FailureMessage {
    /// The text as it would appear, for tests and logging.
    ///
    /// Resolved in English explicitly. Resolving in the current locale would
    /// turn behaviour assertions into language assertions — a test for "does a
    /// 403 explain itself" would start failing the day someone adds a French
    /// translation, on entirely correct code.
    ///
    /// `nonisolated` because it touches only value types, and tests read it
    /// from nonisolated Swift Testing contexts — which newer compilers reject
    /// against the default MainActor isolation this target builds with.
    nonisolated var englishText: String {
        switch self {
        case .app(let resource):
            var copy = resource
            copy.locale = Locale(identifier: "en")
            return String(localized: copy)
        case .server(let text):
            return text
        }
    }
}

extension Label where Title == Text, Icon == Image {
    /// A failure beside an icon.
    ///
    /// Mirrors the SDK's own `Label(_:systemImage:)` so every failure row stays
    /// the one-liner the rest of the app uses, rather than one site hand-writing
    /// the closure form and drifting from its siblings.
    init(_ message: FailureMessage, systemImage name: String) {
        self.init {
            Text(message)
        } icon: {
            Image(systemName: name)
        }
    }
}
