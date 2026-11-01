import SwiftUI

/// 화면 전체가 비었을 때 쓰는 공통 안내. 심볼·제목·설명·주/보조 버튼.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var primaryTitle: String? = nil
    var primarySymbol: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Spacing.xs)

            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 360)

            VStack(spacing: Spacing.m) {
                if let primaryTitle, let primaryAction {
                    Button {
                        primaryAction()
                    } label: {
                        HStack(spacing: 6) {
                            if let primarySymbol { Image(systemName: primarySymbol) }
                            Text(primaryTitle)
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: 280, minHeight: 48)
                        .foregroundStyle(.white)
                        .background(Color.tuneAccent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.tuneAccent)
                        .frame(minHeight: 32)
                }
            }
            .padding(.top, Spacing.s)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xxxl)
        .padding(.vertical, 48)
    }
}
