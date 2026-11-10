import SwiftUI

struct RecordingReviewSectionHeader: View {
    let title: LocalizedStringKey
    let status: LocalizedStringKey
    var isWarning = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .textCase(.uppercase)
                .font(AppVisualStyle.sectionTitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Label(status, systemImage: isWarning ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(AppVisualStyle.sectionTitle)
                .foregroundStyle(isWarning ? .orange : .green)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((isWarning ? Color.orange : .green).opacity(0.1), in: Capsule())
        }
    }
}
