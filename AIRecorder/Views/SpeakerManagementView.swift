import SwiftData
import SwiftUI

struct SpeakerSummaryItem: Identifiable, Equatable {
    let id: UUID
    let speakerID: String
    let name: String
    let fraction: Double
    let duration: TimeInterval
    let colorIndex: Int
}

@MainActor
enum SpeakerSummaryBuilder {
    static func items(for recording: Recording) -> [SpeakerSummaryItem] {
        let totalDuration = max(0.001, recording.speakerTurns.reduce(0) { $0 + $1.duration })
        return recording.orderedSpeakerProfiles.map { profile in
            let duration = recording.speakerTurns
                .filter { $0.speakerID == profile.speakerID }
                .reduce(0) { $0 + $1.duration }
            return .init(
                id: profile.id,
                speakerID: profile.speakerID,
                name: profile.name ?? SpeakerLabelFormatter.displayName(for: profile.speakerID),
                fraction: duration / totalDuration,
                duration: duration,
                colorIndex: profile.colorIndex
            )
        }
    }
}

enum SpeakerPalette {
    static func color(at index: Int) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo, .green, .cyan]
        return colors[index.modulo(colors.count)]
    }
}

struct SpeakerSummaryCard: View {
    let speakers: [SpeakerSummaryItem]
    let hasTranscriptCues: Bool
    let isProcessing: Bool
    let progress: Double?
    let statusText: String?
    let identify: () -> Void
    let edit: () -> Void

    var body: some View {
        Group {
            if isProcessing {
                processingContent
            } else if speakers.isEmpty {
                emptyContent
            } else {
                identifiedContent
            }
        }
        .padding(AppVisualStyle.cardPadding)
        .appCardSurface()
    }

    private var identifiedContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                speakerIcon
                summaryText
                Spacer(minLength: 8)
                editButton
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) { speakerIcon; summaryText }
                editButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var emptyContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                speakerIcon
                emptyText
                Spacer(minLength: 8)
                identifyButton
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    speakerIcon
                    emptyText
                }
                identifyButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var emptyText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Identificar hablantes")
                .font(AppVisualStyle.cardTitle)
            Text(hasTranscriptCues
                 ? "Separa las voces y asígnalas a la transcripción."
                 : "Reconstruye primero la transcripción para analizar las voces.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var identifyButton: some View {
        Button("Identificar", action: identify)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(!hasTranscriptCues)
    }

    private var processingContent: some View {
        HStack(spacing: 14) {
            speakerIcon
            VStack(alignment: .leading, spacing: 8) {
                Text(statusText ?? AppLocalization.string("Identificando hablantes…"))
                    .font(.headline)
                if let progress { ProgressView(value: progress) } else { ProgressView() }
            }
        }
    }

    private var speakerIcon: some View {
        Image(systemName: "person.3.fill")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.blue)
            .frame(width: 52, height: 52)
            .background(.blue.opacity(0.08), in: Circle())
            .accessibilityHidden(true)
    }

    private var summaryText: some View {
        VStack(alignment: .leading, spacing: 3) {
            if speakers.count == 1 {
                Text("1 hablante identificado")
                    .font(AppVisualStyle.cardTitle)
            } else {
                Text("\(speakers.count) hablantes identificados")
                    .font(AppVisualStyle.cardTitle)
            }
            Text(speakerBreakdown)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var editButton: some View {
        Button("Editar etiquetas", action: edit)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.blue.opacity(0.08), in: Capsule())
            .buttonStyle(.plain)
    }

    private var speakerBreakdown: String {
        speakers.map {
            "\($0.name) (\($0.fraction.formatted(.percent.precision(.fractionLength(0)))))"
        }.joined(separator: ", ")
    }
}

private struct PendingSpeakerMerge {
    let sourceID: UUID
    let targetID: UUID
}

struct SpeakerEditorSheet: View {
    let recording: Recording
    let playback: PlaybackController
    let diarization: SpeakerDiarizationController

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var names: [UUID: String] = [:]
    @State private var expectedSpeakerCount = 0
    @State private var playingTurnID: UUID?
    @State private var pendingMerge: PendingSpeakerMerge?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                settingsSection
                ForEach(recording.orderedSpeakerProfiles) { profile in
                    speakerSection(profile)
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(
                .horizontal,
                AppVisualStyle.pageHorizontalPadding,
                for: .scrollContent
            )
            .scrollContentBackground(.hidden)
            .background(AppVisualStyle.screenBackground)
            .navigationTitle("Editar hablantes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        if saveNames() { dismiss() }
                    }
                }
            }
            .task {
                names = Dictionary(uniqueKeysWithValues: recording.speakerProfiles.map {
                    ($0.id, $0.name ?? "")
                })
                expectedSpeakerCount = recording.expectedSpeakerCount ?? 0
            }
            .onChange(of: playback.isPlaying) { _, isPlaying in
                if !isPlaying { playingTurnID = nil }
            }
            .onDisappear {
                playback.pause()
                saveNames()
            }
            .alert("No se pudo completar", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "¿Fusionar estos hablantes?",
                isPresented: Binding(
                    get: { pendingMerge != nil },
                    set: { if !$0 { pendingMerge = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Fusionar", role: .destructive, action: performPendingMerge)
                Button("Cancelar", role: .cancel) { pendingMerge = nil }
            } message: {
                Text("Todos los fragmentos del primer hablante se asignarán al segundo.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var settingsSection: some View {
        Section {
            Picker("Número de hablantes", selection: $expectedSpeakerCount) {
                Text("Automático").tag(0)
                ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
            }
            Button {
                saveNames()
                recording.expectedSpeakerCount = expectedSpeakerCount == 0 ? nil : expectedSpeakerCount
                try? context.save()
                Task { await diarization.diarize(recording: recording, context: context) }
            } label: {
                if diarization.isProcessing {
                    HStack { ProgressView(); Text("Volviendo a identificar…") }
                } else {
                    Label("Volver a identificar hablantes", systemImage: "arrow.clockwise")
                }
            }
            .disabled(diarization.isProcessing)
        } footer: {
            Text("Si conoces el número de personas, indicarlo suele mejorar la separación de voces.")
        }
    }

    @ViewBuilder
    private func speakerSection(_ profile: SpeakerProfile) -> some View {
        let summary = summary(for: profile)
        Section {
            HStack(spacing: 12) {
                Text(initials(for: displayName(for: profile)))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(SpeakerPalette.color(at: profile.colorIndex), in: Circle())
                TextField(
                    SpeakerLabelFormatter.displayName(for: profile.speakerID),
                    text: nameBinding(for: profile)
                )
                .textInputAutocapitalization(.words)
                .font(.headline)
                Spacer()
                Text(summary.fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(sampleTurns(for: profile)) { turn in
                sampleRow(turn, profile: profile)
            }

            if recording.speakerProfiles.count > 1 {
                Menu {
                    ForEach(recording.orderedSpeakerProfiles.filter { $0.id != profile.id }) { target in
                        Button(displayName(for: target)) {
                            pendingMerge = .init(sourceID: profile.id, targetID: target.id)
                        }
                    }
                } label: {
                    Label("Fusionar con otro hablante", systemImage: "arrow.triangle.merge")
                }
            }
        } header: {
            HStack {
                Text(displayName(for: profile))
                Spacer()
                Text(summary.duration.formattedDuration)
            }
        }
    }

    private func sampleRow(_ turn: SpeakerTurn, profile: SpeakerProfile) -> some View {
        HStack(spacing: 12) {
            Button {
                if playingTurnID == turn.id, playback.isPlaying {
                    playback.pause()
                    playingTurnID = nil
                } else {
                    playingTurnID = turn.id
                    playback.playClip(
                        from: max(0, turn.startTime - 0.15),
                        to: min(turn.endTime + 0.15, turn.startTime + 7)
                    )
                }
            } label: {
                Image(systemName: playingTurnID == turn.id && playback.isPlaying
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reproducir muestra de \(displayName(for: profile))")

            VStack(alignment: .leading, spacing: 2) {
                Text("Muestra de voz")
                    .foregroundStyle(.primary)
                Text("\(turn.startTime.formattedDuration) · \(turn.duration.formatted(.number.precision(.fractionLength(1)))) s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(recording.orderedSpeakerProfiles.filter { $0.id != profile.id }) { target in
                    Button(displayName(for: target)) {
                        do {
                            if playingTurnID == turn.id {
                                playback.pause()
                                playingTurnID = nil
                            }
                            try SpeakerPersistenceService.reassign(
                                turn: turn,
                                to: target,
                                recording: recording,
                                context: context
                            )
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Cambiar hablante de esta muestra")
        }
    }

    private func nameBinding(for profile: SpeakerProfile) -> Binding<String> {
        Binding(
            get: { names[profile.id] ?? profile.name ?? "" },
            set: { names[profile.id] = $0 }
        )
    }

    private func summary(for profile: SpeakerProfile) -> SpeakerSummaryItem {
        SpeakerSummaryBuilder.items(for: recording).first(where: { $0.id == profile.id })
            ?? .init(id: profile.id, speakerID: profile.speakerID, name: displayName(for: profile), fraction: 0, duration: 0, colorIndex: profile.colorIndex)
    }

    private func displayName(for profile: SpeakerProfile) -> String {
        let draft = names[profile.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let draft, !draft.isEmpty { return draft }
        return SpeakerLabelFormatter.displayName(for: profile.speakerID)
    }

    private func initials(for name: String?) -> String {
        let resolved = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = resolved.split(whereSeparator: \.isWhitespace)
        let initials = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }

    private func sampleTurns(for profile: SpeakerProfile) -> [SpeakerTurn] {
        let turns = recording.orderedSpeakerTurns.filter {
            $0.speakerID == profile.speakerID && $0.duration >= 0.35
        }
        guard turns.count > 3 else { return turns }
        let bucketSize = Double(turns.count) / 3
        return (0..<3).compactMap { bucket in
            let lower = Int((Double(bucket) * bucketSize).rounded(.down))
            let upper = min(turns.count, Int((Double(bucket + 1) * bucketSize).rounded(.up)))
            guard lower < upper else { return nil }
            return turns[lower..<upper].max {
                ($0.confidence * Float(min($0.duration, 7))) < ($1.confidence * Float(min($1.duration, 7)))
            }
        }
    }

    @discardableResult
    private func saveNames() -> Bool {
        do {
            try SpeakerPersistenceService.saveNames(names, recording: recording, context: context)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func performPendingMerge() {
        guard let pendingMerge,
              let source = recording.speakerProfiles.first(where: { $0.id == pendingMerge.sourceID }),
              let target = recording.speakerProfiles.first(where: { $0.id == pendingMerge.targetID })
        else { return }
        do {
            saveNames()
            try SpeakerPersistenceService.merge(
                source: source,
                into: target,
                recording: recording,
                context: context
            )
            names[source.id] = nil
            self.pendingMerge = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
