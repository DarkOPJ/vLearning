import SwiftUI

struct StatusBadge: View {
    let status: GenerationStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .generating {
                ProgressView()
                    .controlSize(.mini)
                    .tint(status.color)
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
            }
            Text(status.shortLabel)
                .font(.system(.caption2, design: .default, weight: .medium))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(status.color.opacity(0.10))
        .clipShape(Capsule())
    }
}

#Preview {
    HStack(spacing: DS.Space.m) {
        StatusBadge(status: .notStarted)
        StatusBadge(status: .queued)
        StatusBadge(status: .generating)
        StatusBadge(status: .complete)
        StatusBadge(status: .failed)
    }
    .padding()
}
