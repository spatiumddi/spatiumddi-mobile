//
//  KeyboardDismiss.swift
//  SpatiumDDI
//

import SwiftUI
import UIKit

/// A **Done** button above the keyboard, and drag-to-dismiss in the scroll view.
///
/// The keyboard covers the bottom of a `Form`, which on nearly every screen
/// here is where the thing you were about to tap lives — Connect, Sign In,
/// Allocate, Create Record. Typing a value and then being unable to reach the
/// button that uses it is the most reliably annoying thing a phone form does.
///
/// A `.keyboard` toolbar is self-scoping: it exists only while a keyboard is on
/// screen, so applying this to a view with no text entry would add nothing.
/// That is why it is a modifier applied per screen rather than something set
/// once at the root — and the root would not reach sheets anyway, since each
/// presentation is its own toolbar context.
///
/// It matters most on the **numeric** fields. `.numberPad` has no Return key at
/// all, so TTL, priority, weight and port had no dismissal short of tapping
/// some other row and hoping it wasn't a button.
private struct DismissableKeyboard: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Drag down over the list to put the keyboard away, which is what
            // a hand already scrolling expects to do.
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    // The glyph rather than the word. A keyboard toolbar item
                    // renders as a floating pill over whatever row it lands on,
                    // and "Done" makes that pill wide enough to cover the field
                    // you were just typing in — which is the opposite of the
                    // problem this is here to solve. The chevron is also the
                    // conventional "put the keyboard away" symbol, so it needs
                    // no reading.
                    Button {
                        // Resigns whichever field is first responder without
                        // this modifier having to know what the fields are.
                        //
                        // The SwiftUI-native alternative is a `@FocusState`
                        // bound to every field on every screen, which means the
                        // one screen where somebody forgets to bind a field is
                        // the screen where the button silently does nothing.
                        // A modifier that cannot be wired up wrongly is worth
                        // the one UIKit call.
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    // An icon on its own says nothing to VoiceOver.
                    .accessibilityLabel("Hide keyboard")
                }
            }
    }
}

extension View {
    /// Gives this screen a way out of the keyboard: a Done button above it, and
    /// drag-to-dismiss on the scroll view.
    func dismissableKeyboard() -> some View { modifier(DismissableKeyboard()) }
}
