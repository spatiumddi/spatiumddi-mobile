//
//  SpatiumDDIApp.swift
//  SpatiumDDI
//
//  Created by Zachary McGibbon on 2026-08-22.
//

import SwiftUI

@main
struct SpatiumDDIApp: App {
    /// A capture hook, nothing more: the screenshot harness launches the app
    /// with `SPATIUM_FORCE_APPEARANCE=dark` to produce the dark README and
    /// store set. Forcing the *simulator* dark — `simctl ui` or the
    /// `-AppleInterfaceStyle` argument domain — silently fails to reach a
    /// test-managed launch on current toolchains, and the failure mode is a
    /// "dark" run of perfectly light captures. Unset (every real launch),
    /// this is nil and the app follows the system exactly as before.
    private var forcedScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["SPATIUM_FORCE_APPEARANCE"] {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .preferredColorScheme(forcedScheme)
        }
    }
}
