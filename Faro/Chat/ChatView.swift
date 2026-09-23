import SwiftUI

struct ChatView: View {
    @State var viewModel: ChatViewModel
    @State private var showModelBrowser = false
    @State private var showSettings = false
    @State private var showVoice = false
    /// Models that can be switched to without a download. Read once off
    /// the main actor — `body` re-runs on every token and this touches disk.
    @State private var quickModelIDs: [String] = []
    // Auto-scroll only while the user is already at the bottom — otherwise
    // a streaming reply keeps yanking the view back down and they can never
    // scroll up to read earlier messages.
    @State private var isNearBottom = true
    private let downloadCoordinator = ModelDownloadCoordinator.shared
    private let bottomProximityThreshold: CGFloat = 80

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                FaroColor.ink.ignoresSafeArea()

                if viewModel.conversation.messages.isEmpty {
                    emptyState
                } else {
                    transcript(proxy: proxy)
                }

                VStack {
                    Spacer()
                    if !isNearBottom && !viewModel.conversation.messages.isEmpty {
                        ScrollToBottomButton {
                            isNearBottom = true
                            scrollToBottom(proxy)
                        }
                        .padding(.bottom, 8)
                    }
                    VStack(spacing: 8) {
                        if let status = downloadCoordinator.status[viewModel.conversation.modelID] {
                            ModelLoadBand(modelName: currentModelName, status: status)
                        }
                        if let error = viewModel.errorMessage {
                            ErrorBand(message: error) { viewModel.errorMessage = nil }
                        }
                        ComposerView(viewModel: viewModel)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                    // The transcript scrolls underneath, so the composer sits
                    // on a fade into the page rather than a hard band edge.
                    .background(
                        LinearGradient(
                            stops: [
                                .init(color: FaroColor.ink.opacity(0), location: 0),
                                .init(color: FaroColor.ink, location: 0.5),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                }
            }
            .navigationTitle(viewModel.conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem {
                    Button {
                        showVoice = true
                    } label: {
                        Image(systemName: "waveform")
                    }
                    .tint(FaroColor.ash)
                    .accessibilityLabel("Modo voz")
                }
                ToolbarItem {
                    turnMenu
                }
            }
            // Also re-reads when the browser closes, so a model downloaded
            // just now shows up in the quick list.
            .task(id: showModelBrowser) { await refreshQuickModels() }
            .sheet(isPresented: $showModelBrowser) {
                ModelBrowserView(
                    currentModelID: viewModel.conversation.modelID,
                    onSelect: viewModel.changeModel
                )
            }
            .sheet(isPresented: $showSettings) {
                GenerationSettingsSheet(
                    conversation: viewModel.conversation,
                    onDismiss: viewModel.applyGenerationSettingsChange
                )
            }
            .fullScreenCover(isPresented: $showVoice) {
                VoiceView(viewModel: viewModel)
            }
        }
    }

    /// Model, reasoning depth and generation settings all answer the same
    /// question — how this conversation replies — so they live in one
    /// control instead of four competing toolbar buttons.
    private var turnMenu: some View {
        Menu {
            // A Picker inside a Menu renders as a checked list, so the
            // active model is marked without drawing the checkmark here.
            Picker("Modelo", selection: modelBinding) {
                ForEach(quickModelIDs, id: \.self) { id in
                    Text(shortModelName(id)).tag(id)
                }
            }
            Button {
                showModelBrowser = true
            } label: {
                Label("Descargar otro modelo", systemImage: "shippingbox")
            }
            Picker("Razonamiento", selection: thinkingEffortBinding) {
                ForEach(ThinkingEffort.allCases, id: \.self) { effort in
                    Text(effort.label).tag(effort)
                }
            }
            // `nil` (not checked yet) leaves it enabled — only a confirmed
            // `false` disables it, never a guess from the model's name.
            .disabled(viewModel.capabilities?.supportsReasoning == false)
            Picker("Estilo", selection: responseStyleBinding) {
                Text("Predeterminado").tag(ResponseStyle?.none)
                ForEach(ResponseStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(ResponseStyle?.some(style))
                }
            }
            Button {
                showSettings = true
            } label: {
                Label("Generación", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentModelName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.footnote)
            .foregroundStyle(FaroColor.ash)
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { viewModel.conversation.modelID },
            set: { viewModel.changeModel(to: $0) }
        )
    }

    /// The list has to contain the current model or the Picker has nothing
    /// to check — a model still downloading isn't on disk yet.
    private func refreshQuickModels() async {
        let downloaded = await Task.detached(priority: .utility) {
            ModelCacheStore.downloadedIDs()
        }.value
        var ids = downloaded
        if AppleFoundationEngine.isAvailable { ids.insert(AppleFoundationModel.id, at: 0) }
        let current = viewModel.conversation.modelID
        if !ids.contains(current) { ids.append(current) }
        quickModelIDs = ids
    }

    private var thinkingEffortBinding: Binding<ThinkingEffort> {
        Binding(
            get: { viewModel.conversation.thinkingEffort },
            set: { viewModel.setThinkingEffort($0) }
        )
    }

    private var responseStyleBinding: Binding<ResponseStyle?> {
        Binding(
            get: { viewModel.conversation.responseStyle },
            set: { viewModel.setResponseStyle($0) }
        )
    }

    private var currentModelName: String { shortModelName(viewModel.conversation.modelID) }

    private var emptyState: some View {
        VStack(spacing: 18) {
            NuevaConversacionAnimationView()
                .frame(width: 240, height: 240)
            Text("Todo ocurre en este dispositivo")
                .font(.system(size: 16))
                .foregroundStyle(FaroColor.ash)
        }
        .padding(.bottom, 80)
    }

    private struct ModelLoadBand: View {
        let modelName: String
        let status: ModelLoadStatus

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(ModelLoadStatusFormatter.phaseLabel(status)) \(modelName)")
                        .font(.footnote)
                        .foregroundStyle(FaroColor.bone)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(ModelLoadStatusFormatter.line(status))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(FaroColor.ash)
                }
                ProgressView(value: status.fraction)
                    .tint(FaroColor.lamp)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .faroCard()
        }
    }

    private struct ErrorBand: View {
        let message: String
        let onDismiss: () -> Void

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(FaroColor.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FaroColor.ash)
                }
                .accessibilityLabel("Descartar el error")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .faroCard(border: FaroColor.error.opacity(0.35))
        }
    }

    private func transcript(proxy: ScrollViewProxy) -> some View {
        // Sorted once per redraw: `viewModel.messages` re-reads and
        // re-sorts the relationship on every access, and this view redraws
        // on every token.
        let messages = viewModel.messages
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(messages) { message in
                    MessageView(
                        message: message, liveTurn: liveTurn(for: message),
                        viewModel: viewModel, quickModelIDs: quickModelIDs
                    )
                    .id(message.id)
                }
                Color.clear.frame(height: 90).id("bottom")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let distanceFromBottom = geometry.contentSize.height
                - geometry.containerSize.height
                - geometry.contentOffset.y
            return distanceFromBottom < bottomProximityThreshold
        } action: { _, nearBottom in
            isNearBottom = nearBottom
        }
        .onChange(of: messages.last?.content) { scrollToBottomIfNear(proxy) }
        .onChange(of: messages.last?.reasoning) { scrollToBottomIfNear(proxy) }
        // Steps only change at block boundaries (a tool card appearing,
        // a reasoning block closing) — `reasoning` above already covers
        // a block's own growth token by token.
        .onChange(of: messages.last?.stepsRaw) { scrollToBottomIfNear(proxy) }
        .onChange(of: messages.count) {
            isNearBottom = true
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func scrollToBottomIfNear(_ proxy: ScrollViewProxy) {
        guard isNearBottom else { return }
        scrollToBottom(proxy)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private struct ScrollToBottomButton: View {
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FaroColor.bone)
                    .frame(width: 36, height: 36)
                    .background(FaroColor.ink.opacity(0.9), in: Circle())
                    .overlay(Circle().strokeBorder(FaroColor.ash.opacity(0.25)))
            }
            .accessibilityLabel("Ir al final")
        }
    }

    private func liveTurn(for message: ChatMessage) -> MessageView.LiveTurn? {
        guard viewModel.streamingMessageID == message.id else { return nil }
        return MessageView.LiveTurn(phase: viewModel.phase, startedAt: viewModel.phaseStartedAt)
    }
}
