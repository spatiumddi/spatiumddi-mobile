//
//  Brand.swift
//  SpatiumDDI
//

import SwiftUI

/// The logo tile.
///
/// `BrandMark` is the nested-squares mark from the platform's own logo, and it
/// carries its own rounded dark tile — so unlike the wordmark it sits correctly
/// on any background, in either appearance, without alteration.
struct BrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        Image(.brandMark)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The mark with the product name beside it.
///
/// The name is drawn as **text, not the shipped wordmark asset**. `logo.svg`
/// paints an opaque `#0f172a` rectangle across its whole canvas, which is
/// correct on the web console's dark chrome and a dark band anywhere else —
/// it would sit as a black slab on a light-mode phone.
///
/// Rebuilding it natively also buys the things an image cannot: it scales with
/// Dynamic Type, it inherits the appearance-aware accent (teal-600 light,
/// teal-400 dark — the same two values the asset catalogue already defines),
/// and VoiceOver reads a product name rather than announcing an image.
struct BrandLockup: View {
    var markSize: CGFloat = 56
    /// The strapline under the name, where a screen wants one.
    var caption: String?

    @ScaledMetric(relativeTo: .largeTitle) private var nameSize: CGFloat = 30
    @ScaledMetric(relativeTo: .subheadline) private var suffixSize: CGFloat = 16

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                BrandMark(size: markSize)
                VStack(alignment: .leading, spacing: 0) {
                    // A product name. Transliterating it would break the lockup.
                    Text(verbatim: "Spatium")
                        .font(.system(size: nameSize, weight: .bold))
                        .tracking(-0.5)
                    Text(verbatim: "DDI")
                        .font(.system(size: suffixSize, weight: .regular))
                        // The wide tracking is the logo's, not decoration —
                        // it is what makes the lockup recognisable.
                        .tracking(6)
                        .foregroundStyle(.tint)
                }
            }
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        // Built from the caption alone, with the product name prepended
        // verbatim: the name is not a translation unit, and interpolating it
        // into a localised label would make it one.
        .accessibilityLabel(
            Text(verbatim: "SpatiumDDI. ") + Text(caption ?? "")
        )
    }
}

/// The lockup as a `List` header, with the padding a form section wants.
///
/// A separate view rather than a modifier because every screen that shows it is
/// inside a `Form` or `List`, where the row background and separators have to be
/// cleared or the logo sits in a visible cell.
struct BrandHeader: View {
    var caption: String?

    var body: some View {
        BrandLockup(caption: caption)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
}
