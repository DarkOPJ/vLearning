import SwiftUI

/// The vLearning logo: the mark, with the wordmark drawn as text so it reads in light and dark.
struct LogoView: View {
    var markHeight: CGFloat = 64
    var showsWordmark = true

    /// The blue of the "v" in the logo.
    static let blue = Color(red: 0.04, green: 0.48, blue: 1.0)

    var body: some View {
        VStack(spacing: markHeight * 0.18) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: markHeight)
                .accessibilityHidden(true)
            if showsWordmark {
                (Text("v").foregroundStyle(Self.blue) + Text("learning").foregroundStyle(.primary))
                    .font(.system(size: markHeight * 0.5, weight: .bold, design: .rounded))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("vLearning")
    }
}

#Preview {
    VStack(spacing: 40) {
        LogoView()
        LogoView(markHeight: 32)
    }
    .padding()
}
