import SwiftUI
import UIKit

enum Theme {
    static let brand = adaptive(
        light: (0.06, 0.32, 0.34),
        dark:  (0.45, 0.80, 0.80)
    )

    static let brandSoft = adaptive(
        light: (0.17, 0.54, 0.56),
        dark:  (0.33, 0.68, 0.70)
    )

    static let signal = adaptive(
        light: (0.80, 0.45, 0.10),
        dark:  (0.98, 0.70, 0.33)
    )

    static let signalWash = signal.opacity(0.16)

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

extension Font {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.brandSoft.opacity(0.7))
            Text(title)
                .font(.display(18))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

struct GlassCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

extension View {
    func glassCircle() -> some View {
        modifier(GlassCircleBackground())
    }
}
