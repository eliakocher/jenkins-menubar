#if DEBUG
import SwiftUI

/// The gallery's first entry: a few standard components, and the environment the gallery set, so a screenshot shows
/// that the appearance and accessibility overrides reach the views.
struct GalleryPlaceholderView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("MegaMonitor gallery", systemImage: "square.grid.2x2")
                .font(.title2)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Color scheme", "\(colorScheme)")
                row("Contrast", "\(contrast)")
                row("Type size", "\(typeSize)")
                row("Reduce transparency", "\(reduceTransparency)")
                row("Reduce motion", "\(reduceMotion)")
                row("Control state", "\(activeState)")
            }
            ProgressView(value: 0.6) {
                Text("Build progress")
            }
            HStack {
                Button("Open build") {}
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") {}
                Spacer()
                Text("Glass")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name)
                .foregroundStyle(.secondary)
            Text(value)
                .monospaced()
        }
    }
}
#endif
