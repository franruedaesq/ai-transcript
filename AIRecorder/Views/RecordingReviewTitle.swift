import SwiftUI

struct RecordingReviewTitle: View {
    let title: String
    let metadata: String

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
