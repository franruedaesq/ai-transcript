import SwiftUI

struct RecordingReviewCueCard: View {
    let speakerName: String?
    let speakerColor: Color
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let secondaryText: String?
    let textFont: Font
    let isActive: Bool
    let select: () -> Void
    let edit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if let speakerName {
                    Label(speakerName, systemImage: isActive ? "circle.fill" : "person.fill")
                        .labelStyle(CompactSpeakerLabelStyle())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? .white : speakerColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                        .layoutPriority(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(isActive ? speakerColor : speakerColor.opacity(0.1), in: .rect(cornerRadius: 6))
                }

                Spacer(minLength: 4)

                Text("\(startTime.formattedDuration) – \(endTime.formattedDuration)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? speakerColor : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if let edit {
                    Button("Editar bloque", systemImage: "pencil", action: edit)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }

            Button(action: select) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text)
                        .font(textFont)
                        .lineSpacing(5)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let secondaryText, !secondaryText.isEmpty {
                        Text(secondaryText)
                            .font(.callout)
                            .italic()
                            .lineSpacing(4)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 13)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(isActive ? speakerColor : Color.secondary.opacity(0.3))
                                    .frame(width: 3)
                            }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(AppVisualStyle.cardPadding)
        .appCardSurface(isSelected: isActive, selectedColor: speakerColor)
        .accessibilityElement(children: .contain)
    }
}

private struct CompactSpeakerLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 6))
            configuration.title
        }
    }
}
