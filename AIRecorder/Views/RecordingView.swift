import SwiftData
import SwiftUI

struct RecordingView: View {
    let settings: AppSettings
    let session: RecordingSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var didStart = false

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.state == .paused ? "En pausa" : "Grabando")
                        .font(.headline).foregroundStyle(session.state == .paused ? .orange : .red)
                    Text(settings.language.displayName).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cerrar") { Task { _ = await session.stop(); dismiss() } }
                    .disabled(session.state == .preparing)
            }

            Text(session.elapsed.formattedDuration)
                .font(.system(size: 48, weight: .light, design: .rounded))
                .monospacedDigit()
                .padding(.top, 8)

            LiveWaveform(values: session.waveform)
                .frame(height: 84)
                .accessibilityLabel("Nivel de audio")

            if settings.translationEnabled {
                VStack(spacing: 10) {
                    LiveTextPanel(
                        title: "Transcripción",
                        updateToken: session.liveTranscript,
                        accessibilityLabel: "Transcripción en vivo"
                    ) {
                        Text(session.liveTranscript.isEmpty ? "La transcripción aparecerá aquí…" : session.liveTranscript)
                            .font(.title3)
                            .lineSpacing(7)
                            .foregroundStyle(session.liveTranscript.isEmpty ? .secondary : .primary)
                    }

                    LiveTextPanel(
                        title: "Traducción · \(TranslationPolicy.displayName(for: settings.translationTargetLanguage))",
                        updateToken: translationUpdateToken,
                        accessibilityLabel: "Traducción en vivo"
                    ) {
                        translationContent
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                LiveTextPanel(
                    title: "Transcripción",
                    updateToken: session.liveTranscript,
                    accessibilityLabel: "Transcripción en vivo"
                ) {
                    Text(session.liveTranscript.isEmpty ? "La transcripción aparecerá aquí…" : session.liveTranscript)
                        .font(.title3)
                        .lineSpacing(7)
                        .foregroundStyle(session.liveTranscript.isEmpty ? .secondary : .primary)
                }
                .frame(maxHeight: .infinity)
            }

            if session.modelPreparation.isBusy {
                VStack(spacing: 8) {
                    if let progress = session.modelPreparation.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                    HStack {
                        Text(session.modelPreparation.label)
                        Spacer()
                        if let progress = session.modelPreparation.progress {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        }
                    }
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Transcripción local · El modelo está listo", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.blue)
            }

        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .safeAreaInset(edge: .bottom) {
            controls
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .background(.ultraThinMaterial)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .interactiveDismissDisabled(session.state != .idle)
        .task {
            guard !didStart else { return }
            didStart = true
            await session.start(settings: settings, context: context)
        }
        .alert("Error", isPresented: Binding(
            get: { if case .failed = session.state { true } else { false } },
            set: { if !$0 { session.resetError(); dismiss() } }
        )) { Button("Cerrar") { session.resetError(); dismiss() } } message: {
            if case .failed(let message) = session.state { Text(message) }
        }
    }

    private var translationUpdateToken: String {
        let frozen = session.liveTranslationBlocks.map { "\($0.id)-\($0.translatedText ?? "")-\($0.state.rawValue)" }.joined()
        let active = session.activeTranslation.map { "\($0.id)-\($0.translatedText ?? "")-\($0.state.rawValue)" } ?? ""
        return frozen + active + (session.translationNotice ?? "")
    }

    @ViewBuilder
    private var translationContent: some View {
        if let notice = session.translationNotice {
            Label(notice, systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if session.liveTranslationBlocks.isEmpty, session.activeTranslation == nil {
            Text("La traducción aparecerá aquí…")
                .font(.title3)
                .foregroundStyle(.secondary)
        } else {
            ForEach(session.liveTranslationBlocks) { block in
                TranslationBlockView(block: block)
            }
            if let block = session.activeTranslation {
                TranslationBlockView(block: block)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 52) {
            Button {
                Task { session.state == .paused ? await session.resume() : await session.pause() }
            } label: {
                Image(systemName: session.state == .paused ? "play.fill" : "pause.fill")
                    .font(.title2).frame(width: 58, height: 58)
            }
            .buttonStyle(.recorderGlass)
            .disabled(session.state != .recording && session.state != .paused)
            .accessibilityLabel(session.state == .paused ? "Reanudar" : "Pausar")

            Button {
                Task { _ = await session.stop(); dismiss() }
            } label: {
                RoundedRectangle(cornerRadius: 7).fill(.white).frame(width: 27, height: 27)
                    .frame(width: 82, height: 82).background(.red, in: Circle())
                    .overlay(Circle().stroke(.red.opacity(0.22), lineWidth: 10).padding(-5))
            }
            .disabled(session.state != .recording && session.state != .paused)
            .accessibilityLabel("Detener")

            Color.clear.frame(width: 58, height: 58)
        }.padding(.bottom, 10)
    }
}

private struct TranslationBlockView: View {
    let block: LiveTranslationBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let translated = block.translatedText {
                Text(translated)
                    .font(.title3)
                    .foregroundStyle(block.state == .final ? .primary : .secondary)
                    .italic(block.state != .final)
                    .lineSpacing(6)
            }
            if block.state == .translating || block.state == .waiting {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(block.translatedText == nil ? "Traduciendo…" : "Revisando…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if block.state == .provisional {
                Text("Traducción provisional…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if block.state == .failed {
                Label("No se pudo traducir", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(block.state == .final ? "Traducción final" : "Traducción provisional")
        .accessibilityValue(block.translatedText ?? "Pendiente")
    }
}

private struct LiveTextPanel<Content: View>: View {
    let title: String
    let updateToken: String
    let accessibilityLabel: String
    @ViewBuilder let content: Content
    @State private var followsLatest = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        content
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentMargins(16, for: .scrollContent)
                .simultaneousGesture(DragGesture().onChanged { _ in followsLatest = false })
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        Button {
                            followsLatest = true
                            withAnimation { proxy.scrollTo("tail", anchor: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down")
                                .frame(width: 34, height: 34)
                                .background(.regularMaterial, in: Circle())
                        }
                        .padding(10)
                        .accessibilityLabel("Ir al texto más reciente")
                    }
                }
                .onChange(of: updateToken) { _, _ in
                    guard followsLatest else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("tail", anchor: .bottom) }
                }
            }
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct LiveWaveform: View {
    let values: [Float]
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Capsule().fill(.red.opacity(0.82)).frame(width: max(2, geometry.size.width / CGFloat(values.count) - 3), height: max(4, geometry.size.height * CGFloat(value)))
                }
            }.frame(maxHeight: .infinity)
        }
    }
}
