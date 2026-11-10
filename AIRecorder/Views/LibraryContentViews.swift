import SwiftUI

struct LibraryHeader: View {
    @Binding var searchText: String
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .center, spacing: 16) {
                Text("AI Recorder")
                    .font(AppVisualStyle.screenTitle)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)

                Button("Ajustes", systemImage: "gearshape", action: openSettings)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.background, in: Circle())
                    .overlay(Circle().stroke(.secondary.opacity(0.16), lineWidth: 1))
                    .buttonStyle(.plain)
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(AppVisualStyle.mutedText.opacity(0.75))
                    .accessibilityHidden(true)

                TextField(
                    "Buscar grabaciones, transcripciones o etiquetas",
                    text: $searchText,
                    prompt: Text("Buscar grabaciones, transcripciones o etiquetas")
                        .foregroundStyle(AppVisualStyle.mutedText.opacity(0.72))
                )
                    .textFieldStyle(.plain)
                    .submitLabel(.search)

                if !searchText.isEmpty {
                    Button("Borrar búsqueda", systemImage: "xmark.circle.fill") {
                        searchText = ""
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .font(.subheadline)
            .padding(.leading, 15)
            .padding(.trailing, searchText.isEmpty ? 15 : 2)
            .frame(minHeight: 48)
            .background(.background.opacity(0.58), in: Capsule())
            .overlay(Capsule().stroke(.secondary.opacity(0.13), lineWidth: 1))
        }
    }
}

struct LibraryEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 26) {
                EmptyRecordingIllustration()
                Text("Aún no hay grabaciones")
                    .font(.title3.bold())
            }
        } description: {
            Text("Pulsa el botón rojo para grabar tu primera reunión, nota de voz o conversación en directo.")
                .font(.subheadline)
                .foregroundStyle(AppVisualStyle.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        } actions: {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    LibraryFeaturePill(title: "Nota de voz", systemImage: "mic", iconColor: .cyan)
                    LibraryFeaturePill(title: "En directo", systemImage: "ellipsis.message", iconColor: .primary)
                }
                LibraryFeaturePill(title: "Traducción bilingüe", systemImage: "globe", iconColor: .blue)
            }
            .padding(.top, 14)
        }
    }
}

private struct EmptyRecordingIllustration: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(.blue.opacity(0.07))
                .frame(width: 96, height: 96)
                .overlay(Circle().stroke(.blue.opacity(0.14), lineWidth: 1))

            Circle()
                .fill(.background)
                .frame(width: 64, height: 64)
                .overlay(Circle().stroke(.secondary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 7, y: 3)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.title.bold())
                        .foregroundStyle(.blue)
                }
                .frame(width: 96, height: 96)

            Image(systemName: "sparkles")
                .font(.caption.bold())
                .foregroundStyle(.yellow)
                .frame(width: 28, height: 28)
                .background(.background, in: Circle())
                .overlay(Circle().stroke(.secondary.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                .offset(x: 3, y: -3)
        }
        .accessibilityHidden(true)
    }
}

private struct LibraryFeaturePill: View {
    let title: LocalizedStringKey
    let systemImage: String
    let iconColor: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(LibraryFeatureLabelStyle(iconColor: iconColor))
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 13)
            .frame(minHeight: 36)
            .background(.background.opacity(0.7), in: Capsule())
            .overlay(Capsule().stroke(.secondary.opacity(0.13), lineWidth: 1))
    }
}

private struct LibraryFeatureLabelStyle: LabelStyle {
    let iconColor: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .foregroundStyle(iconColor)
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}

struct RecordingLibraryCard: View {
    let recording: Recording
    let coordinator: RecordingExportCoordinator
    let isSelected: Bool
    let open: (() -> Void)?
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            destination
                .padding(.trailing, 42)

            RecordingActionsMenu(
                recording: recording,
                coordinator: coordinator,
                includeDelete: true,
                rename: rename,
                delete: delete
            )
            .disabled(recording.status == .processing)
            .tint(AppVisualStyle.mutedText)
            .frame(width: 44, height: 44)
            .padding(.top, 14)
            .padding(.trailing, 8)
        }
        .appCardSurface(isSelected: isSelected)
        .contextMenu {
            Button("Renombrar", systemImage: "pencil", action: rename)
            if recording.status != .processing {
                Button("Eliminar", systemImage: "trash", role: .destructive, action: delete)
            }
        }
    }

    @ViewBuilder
    private var destination: some View {
        if let open {
            Button(action: open) {
                RecordingLibraryCardContent(recording: recording)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(recording.status == .processing)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            NavigationLink(value: recording.id) {
                RecordingLibraryCardContent(recording: recording)
            }
            .buttonStyle(.plain)
            .disabled(recording.status == .processing)
        }
    }
}

private struct RecordingLibraryCardContent: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(recording.title)
                    .font(AppVisualStyle.cardTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                    .allowsTightening(true)

                statusOrTimeBadge

                Spacer(minLength: 4)

                Text(languageCode)
                    .font(.caption.bold())
                    .foregroundStyle(languageCode == "ES" ? .blue : .primary)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 26)
                    .background(languageCode == "ES" ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(languageCode == "ES" ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.12), lineWidth: 1))
            }

            HStack(spacing: 9) {
                Text(recording.createdAt, format: .dateTime.day().month(.abbreviated).year())
                Text("·")
                Text(recording.duration.formattedDuration)
                    .monospacedDigit()
                Text("·")
                Text(metadataLabel)
                    .lineLimit(1)
            }
            .font(.caption.monospaced())
            .foregroundStyle(AppVisualStyle.mutedText)

            if !excerpt.isEmpty {
                Text("“\(excerpt)”")
                    .font(.subheadline.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        AppVisualStyle.insetBackground,
                        in: RoundedRectangle(cornerRadius: AppVisualStyle.insetCornerRadius)
                    )
            }
        }
        .padding(AppVisualStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusOrTimeBadge: some View {
        if recording.status == .interrupted {
            Text("Interrumpida")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .background(.orange.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(.orange.opacity(0.38), lineWidth: 1))
        } else if recording.status != .saved {
            Text("Procesando")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        } else {
            Text(recording.createdAt, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(minHeight: 26)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var languageCode: String {
        if let detected = recording.detectedLanguage,
           let code = SpokenLanguageResolver.canonicalCode(detected) {
            return code.uppercased()
        }
        return recording.requestedLanguage.translationSourceCode?.uppercased() ?? "AUTO"
    }

    private var metadataLabel: LocalizedStringKey {
        if recording.status == .interrupted { return "Guardado automáticamente" }
        if recording.translationEnabled || !recording.translatedCues.isEmpty { return "Sincronización dual" }
        if recording.source == .imported { return "Audio importado" }
        return "AAC 128 kbps"
    }

    private var excerpt: String {
        let source = recording.transcript.isEmpty ? recording.orderedCues.first?.text ?? "" : recording.transcript
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension View {
    func libraryStatusCard() -> some View {
        padding(AppVisualStyle.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCardSurface()
    }
}
