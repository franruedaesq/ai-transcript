import SwiftData
import SwiftUI
import UIKit

struct RecordingView: View {
    let settings: AppSettings
    let session: RecordingSessionController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appLayoutMode) private var appLayoutMode
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var didStart = false
    @State private var isStopping = false
    @AppStorage("recorder.translationSplitRatio") private var translationSplitRatio = 0.5
    @AppStorage("recorder.translationSplitRatio.iPad") private var iPadTranslationSplitRatio = 0.5
    @AppStorage("recorder.keepScreenAwake") private var keepScreenAwake = false
    @ScaledMetric(relativeTo: .title) private var elapsedFontSize = 30

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recordingStatusTitle)
                        .font(.headline).foregroundStyle(session.state == .paused ? .orange : .red)
                    languageRouteLabel
                }
                Spacer()
                Button("Cerrar", action: stopAndDismiss)
                    .disabled(isStopping || session.state == .preparing || session.state == .finalizing)
            }

            HStack(spacing: 14) {
                Text(session.elapsed.formattedDuration)
                    .font(.system(size: elapsedFontSize, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 104, alignment: .leading)

                LiveWaveform(values: session.waveform)
                    .frame(height: 38)
                    .accessibilityLabel("Nivel de audio")
            }
            .padding(.vertical, 4)

            recordingHealthStrip

            if let notice = session.sessionNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            if let progress = session.finalizationProgress {
                ProgressView(value: progress)
            }

            if settings.translationEnabled {
                ResizableTextPanels(
                    axis: usesSideBySidePanels ? .horizontal : .vertical,
                    splitRatio: usesSideBySidePanels ? $iPadTranslationSplitRatio : $translationSplitRatio
                ) {
                    transcriptPanel
                } secondary: {
                    translationPanel
                }
                .frame(maxHeight: .infinity)
            } else {
                transcriptPanel
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
        .padding(.horizontal, AppVisualStyle.pageHorizontalPadding)
        .padding(.top, 12)
        .safeAreaInset(edge: .bottom) {
            controls
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .background(.ultraThinMaterial)
        }
        .background(AppVisualStyle.screenBackground.ignoresSafeArea())
        .interactiveDismissDisabled(session.state != .idle)
        .task {
            guard !didStart else { return }
            didStart = true
            await session.start(settings: settings, context: context)
            updateIdleTimer(for: session.state)
        }
        .onChange(of: session.state) { _, state in updateIdleTimer(for: state) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.persistRecoveryNow() } }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .alert("Error", isPresented: Binding(
            get: { if case .failed = session.state { true } else { false } },
            set: { if !$0 { session.resetError(); dismiss() } }
        )) { Button("Cerrar") { session.resetError(); dismiss() } } message: {
            if case .failed(let message) = session.state { Text(message) }
        }
    }

    private var usesSideBySidePanels: Bool {
        appLayoutMode == .pad
            && horizontalSizeClass == .regular
            && !dynamicTypeSize.isAccessibilitySize
    }

    private var transcriptPanel: some View {
        LiveTextPanel(
            title: AppLocalization.string("Transcripción"),
            updateToken: transcriptUpdateToken,
            accessibilityLabel: AppLocalization.string("Transcripción en vivo")
        ) {
            if session.liveTranscriptBlocks.isEmpty, session.liveTranscriptProvisional.isEmpty {
                Text(AppLocalization.string("La transcripción aparecerá aquí…"))
                    .font(.body).foregroundStyle(.secondary)
            } else {
                ForEach(session.liveTranscriptBlocks) { block in
                    Text(block.text).font(.body).lineSpacing(5).textSelection(.enabled)
                }
                if !session.liveTranscriptProvisional.isEmpty {
                    Text(session.liveTranscriptProvisional).font(.body).lineSpacing(5).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private var transcriptUpdateToken: String { "\(session.liveTranscriptBlocks.count)-\(session.liveTranscriptProvisional)" }

    private var recordingStatusTitle: String {
        switch session.state {
        case .idle: AppLocalization.string("Lista")
        case .preparing: AppLocalization.string("Preparando…")
        case .recording: AppLocalization.string("Grabando")
        case .paused: AppLocalization.string("En pausa")
        case .finalizing: session.finalizationLabel ?? AppLocalization.string("Guardando…")
        case .failed: AppLocalization.string("Interrumpida")
        }
    }

    private var languageRouteLabel: some View {
        HStack(spacing: 6) {
            Text(sourceLanguageLabel)
            if settings.translationEnabled {
                Image(systemName: "arrow.right").font(.caption2)
                Text(TranslationPolicy.displayName(for: settings.translationTargetLanguage))
            }
        }.font(.subheadline).foregroundStyle(.secondary)
    }

    private var sourceLanguageLabel: String {
        if settings.language == .automatic, let detected = session.detectedLanguage {
            return AppLocalization.string("Auto · \(TranslationPolicy.displayName(for: detected))")
        }
        return settings.language.displayName
    }

    private var translationPanel: some View {
        LiveTextPanel(
            title: AppLocalization.string("Traducción · \(TranslationPolicy.displayName(for: settings.translationTargetLanguage))"),
            updateToken: translationUpdateToken,
            accessibilityLabel: AppLocalization.string("Traducción en vivo")
        ) {
            translationContent
        }
    }

    private func updateIdleTimer(for state: RecordingSessionState) {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake && state == .recording
    }

    @ViewBuilder private var recordingHealthStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let route = session.activeInputRoute { Label(route.name, systemImage: route.systemImage).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
            if let warning = session.inputWarning { Label(warning, systemImage: "waveform.slash").font(.caption.weight(.medium)).foregroundStyle(.orange) }
            if let notice = session.lastMarkerNotice { Label(notice, systemImage: "bookmark.fill").font(.caption.weight(.medium)).foregroundStyle(.blue) }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.body)
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
            .accessibilityLabel(AppLocalization.string(session.state == .paused ? "Reanudar" : "Pausar"))

            Button {
                stopAndDismiss()
            } label: {
                RoundedRectangle(cornerRadius: 7).fill(.white).frame(width: 27, height: 27)
                    .frame(width: 82, height: 82).background(.red, in: Circle())
                    .overlay(Circle().stroke(.red.opacity(0.22), lineWidth: 10).padding(-5))
            }
            .disabled(isStopping || (session.state != .recording && session.state != .paused))
            .accessibilityLabel("Detener")

            Button { session.addMarker() } label: { Image(systemName: "bookmark.fill").font(.title2).frame(width: 58, height: 58) }
                .buttonStyle(.recorderGlass)
                .disabled(session.state != .recording && session.state != .paused)
                .accessibilityLabel("Agregar marcador")
        }.padding(.bottom, 10)
    }

    private func stopAndDismiss() {
        guard !isStopping else { return }
        guard session.state == .recording || session.state == .paused else {
            dismiss()
            return
        }
        isStopping = true
        Task {
            if await session.stop() != nil {
                dismiss()
            } else {
                isStopping = false
            }
        }
    }
}

private struct TranslationBlockView: View {
    let block: LiveTranslationBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let translated = block.translatedText {
                Text(translated)
                    .font(.body)
                    .foregroundStyle(block.state == .final ? .primary : .secondary)
                    .italic(block.state != .final)
                    .lineSpacing(6)
            }
            if block.state == .translating || block.state == .waiting {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(AppLocalization.string(block.translatedText == nil ? "Traduciendo…" : "Revisando…"))
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
        .accessibilityLabel(AppLocalization.string(block.state == .final ? "Traducción final" : "Traducción provisional…"))
        .accessibilityValue(block.translatedText ?? AppLocalization.string("Pendiente"))
    }
}

private struct LiveTextPanel<Content: View>: View {
    let title: String
    let updateToken: String
    let accessibilityLabel: String
    @ViewBuilder let content: Content
    @State private var followsLatest = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($scrollPosition)
            .contentMargins(16, for: .scrollContent)
            .simultaneousGesture(DragGesture().onChanged { _ in followsLatest = false })
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        scrollToLatest()
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
                scrollToLatest()
            }
            .appInsetSurface()
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func scrollToLatest() {
        scrollPosition.scrollTo(edge: .bottom)
        Task { @MainActor in
            await Task.yield()
            scrollPosition.scrollTo(edge: .bottom)
        }
    }
}

private enum TextPanelAxis: Equatable {
    case horizontal
    case vertical
}

private struct ResizableTextPanels<Primary: View, Secondary: View>: View {
    let axis: TextPanelAxis
    @Binding var splitRatio: Double
    @ViewBuilder let primary: Primary
    @ViewBuilder let secondary: Secondary
    @State private var ratioAtDragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            if axis == .horizontal {
                let dividerWidth = 28.0
                let availableWidth = max(0, geometry.size.width - dividerWidth)
                HStack(spacing: 0) {
                    primary
                        .frame(width: availableWidth * CGFloat(splitRatio))
                    splitHandle(availableLength: availableWidth)
                        .frame(width: dividerWidth)
                    secondary
                        .frame(width: availableWidth * CGFloat(1 - splitRatio))
                }
            } else {
                let dividerHeight = 28.0
                let availableHeight = max(0, geometry.size.height - dividerHeight)
                VStack(spacing: 0) {
                    primary
                        .frame(height: availableHeight * CGFloat(splitRatio))
                    splitHandle(availableLength: availableHeight)
                        .frame(height: dividerHeight)
                    secondary
                        .frame(height: availableHeight * CGFloat(1 - splitRatio))
                }
            }
        }
    }

    private func splitHandle(availableLength: CGFloat) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.45))
            .frame(
                width: axis == .horizontal ? 5 : 44,
                height: axis == .horizontal ? 44 : 5
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard availableLength > 0 else { return }
                        if ratioAtDragStart == nil { ratioAtDragStart = splitRatio }
                        let initialRatio = ratioAtDragStart ?? splitRatio
                        let translation = axis == .horizontal ? value.translation.width : value.translation.height
                        splitRatio = clamped(initialRatio + Double(translation / availableLength))
                    }
                    .onEnded { _ in ratioAtDragStart = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Ajustar espacio entre transcripción y traducción")
            .accessibilityValue(Text(splitRatio, format: .percent.precision(.fractionLength(0))))
            .accessibilityHint(axis == .horizontal ? "Ajusta el ancho de los paneles" : "Ajusta la altura de los paneles")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: splitRatio = clamped(splitRatio + 0.1)
                case .decrement: splitRatio = clamped(splitRatio - 0.1)
                @unknown default: break
                }
            }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0.2), 0.8)
    }
}

private struct LiveWaveform: View {
    let values: [Float]
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Capsule().fill(.red.opacity(0.82)).frame(width: max(1, geometry.size.width / CGFloat(values.count) - 2), height: max(3, geometry.size.height * CGFloat(value)))
                }
            }.frame(maxHeight: .infinity)
        }
    }
}
