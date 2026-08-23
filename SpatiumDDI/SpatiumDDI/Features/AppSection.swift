//
//  AppSection.swift
//  SpatiumDDI
//

import Foundation

/// One destination in the app's sidebar.
///
/// A sidebar rather than a tab bar, and not only as a matter of taste. Seven
/// tabs do not fit on a phone, so UIKit pushes the overflow into a "More" list
/// that wraps them in *its own* navigation controller — and since every section
/// here is already a navigation stack, that nesting drew two navigation bars and
/// two back buttons on exactly the sections that overflowed. A sidebar has no
/// overflow, so the problem cannot recur as sections are added.
nonisolated enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview
    case alerts
    case ipam
    case dns
    case dhcp
    case search
    case server

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .alerts: "Alerts"
        case .ipam: "IPAM"
        case .dns: "DNS"
        case .dhcp: "DHCP"
        case .search: "Search"
        case .server: "Server"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .alerts: "bell"
        case .ipam: "square.grid.3x3"
        case .dns: "globe"
        case .dhcp: "arrow.left.arrow.right"
        case .search: "magnifyingglass"
        case .server: "gear"
        }
    }

    /// Grouped so the sidebar reads as the estate first, then the tools, then
    /// the connection — rather than as seven equally-weighted items.
    enum Group: String, CaseIterable, Identifiable {
        case monitor = "Monitor"
        case estate = "Estate"
        case tools = "Tools"

        var id: Self { self }

        var sections: [AppSection] {
            switch self {
            case .monitor: [.overview, .alerts]
            case .estate: [.ipam, .dns, .dhcp]
            case .tools: [.search, .server]
            }
        }
    }
}
