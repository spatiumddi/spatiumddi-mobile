//
//  BreadcrumbBar.swift
//  SpatiumDDI
//

import SwiftUI

/// Where this screen sits in the tree, pinned under the navigation bar.
///
/// IPAM is four levels deep and every level is named in the same vocabulary —
/// a CIDR under a CIDR under a name. The navigation title says which row you
/// opened; it cannot say which of three `10.0.0.0/8` blocks you opened it from,
/// and on a phone the back button truncates to "Back" long before it helps.
///
/// Shows **ancestors only**, and not the root: the title already says where you
/// are, and "IP Spaces" is on every screen and therefore locates nothing. The
/// bar is absent entirely one level down, where the back button is the whole
/// answer — chrome that says nothing is worse than no chrome.
///
/// Deliberately **not tappable**. Popping to an arbitrary ancestor needs a
/// path-driven `NavigationStack` rather than the destination-based links these
/// screens use, and that is a navigation restructure — the same area that
/// produced the double back button — not a decoration to bolt onto one.
struct BreadcrumbBar: View {
    let trail: [String]

    private var crumbs: some View {
        HStack(spacing: 5) {
            ForEach(Array(trail.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // The control plane's own names for these rows, shown
                // as sent — never translated, never Markdown-parsed.
                Text(verbatim: crumb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    var body: some View {
        if !trail.isEmpty {
            // A trail that fits is laid out plainly; only genuine overflow
            // gets a ScrollView. The previous shape — always a ScrollView,
            // with `.defaultScrollAnchor(.trailing)` to right-align undersized
            // content — rendered the strip with its text scrolled clean out of
            // the viewport on the iOS 27 beta: the bar took its space and drew
            // its divider, and the crumbs themselves were never visible. Keep
            // the anchor only where there is actually something to anchor.
            ViewThatFits(in: .horizontal) {
                crumbs.frame(maxWidth: .infinity, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) { crumbs }
                    // Anchored to the end, so the crumb you can see is the
                    // nearest ancestor — the one that actually locates you.
                    .defaultScrollAnchor(.trailing)
            }
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text("Inside") + Text(verbatim: " \(trail.joined(separator: ", "))")
            )
        }
    }
}

extension View {
    /// Pins the trail of ancestors above this screen's content.
    func breadcrumbs(_ trail: [String]) -> some View {
        safeAreaInset(edge: .top, spacing: 0) { BreadcrumbBar(trail: trail) }
    }
}

#Preview {
    NavigationStack {
        List {
            Text(verbatim: "10.0.1.7")
            Text(verbatim: "10.0.1.8")
        }
        .navigationTitle("10.0.1.0/24")
        .navigationBarTitleDisplayMode(.inline)
        .breadcrumbs(["Default", "10.0.0.0/8"])
    }
}
