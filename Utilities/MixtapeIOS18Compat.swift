#if os(iOS)
import SwiftUI

// Backwards-compatible visual features for iOS 18.
// All native iOS 26 behavior is preserved on iOS 26+.
extension View {
    @ViewBuilder
    func mixtapeCompatTabBarMinimizeOnScrollDown() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    @ViewBuilder
    func mixtapeCompatTabViewBottomAccessory<Accessory: View>(
        @ViewBuilder content: () -> Accessory
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.tabViewBottomAccessory(content: content)
        } else {
            // iOS 18 fallback: render the accessory, but inject
            // PlayerBarAppearance directly at its use site.
            self.overlay(alignment: .bottom) {
                          content()
                              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                              .padding(.horizontal, 12)
                              .padding(.top, 6)
                              // The iOS 18 system tab bar is about 50-60pt high.
                              .padding(.bottom, 62)
                      }
        }
    }

    @ViewBuilder
    func mixtapeCompatGlassEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect()
        } else {
            self.background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
#endif

import SwiftUI

// iOS18: the player is a floating overlay. Give actual ScrollView/List
// content an unobstructed end position; a spacer around NavigationStack
// (the v29 approach) does not reliably protect nested lists.
private struct MixtapeMiniPlayerVisibleKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var mixtapeMiniPlayerVisible: Bool {
        get { self[MixtapeMiniPlayerVisibleKey.self] }
        set { self[MixtapeMiniPlayerVisibleKey.self] = newValue }
    }
}

private struct MixtapeScrollAbovePlayer: ViewModifier {
    @Environment(\.mixtapeMiniPlayerVisible) private var isVisible

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if isVisible {
                Color.clear.frame(height: 150).allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func mixtapeScrollAbovePlayer() -> some View {
        modifier(MixtapeScrollAbovePlayer())
    }
}
