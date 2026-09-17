import SwiftUI

struct ChatView: View {
    @State var viewModel: ChatViewModel
    @State private var showModelBrowser = false
    @State private var showSettings = false
    @State private var showVoice = false
    private let downloadCoordinator = ModelDownloadCoordinator.shared

    var body: some View {
        ZStack {
            FaroColor.ink.ignoresSafeArea()

            if viewModel.messages.isEmpty {
                emptyState
            } else {
                transcript
            }

            VStack {
                Spacer()
                VStack(spacing: 8) {
                    if let status = downloadCoordinator.status[viewModel.conversation.modelID] {
                        ModelLoadBand(modelName: shortModelName, status: status)
                    }
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FaroColor.error.opacity(0.4), in: .rect(cornerRadius: 12))
                    }
                    ComposerView(viewModel: viewModel)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .navigationTitle(viewModel.conversation.title)
        .toolbar {
            ToolbarItem {
                Button {
                    showVoice = true
                } label: {
                    Image(systemName: "mic")
                }
            }
            ToolbarItem {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
            ToolbarItem {
                Menu {
                    ForEach(ThinkingEffort.allCases, id: \.self) { effort in
                        Button(effort.label) { viewModel.setThinkingEffort(effort) }
                    }
                } label: {
                    Text(viewModel.conversation.thinkingEffort.label)
                        .font(.footnote)
                        .foregroundStyle(FaroColor.ash)
                }
            }
            ToolbarItem {
                Button {
                    showModelBrowser = true
                } label: {
                    Text(shortModelName)
                        .font(.footnote)
                        .foregroundStyle(FaroColor.ash)
                }
            }
        }
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

    private var shortModelName: String {
        viewModel.conversation.modelID.split(separator: "/").last.map(String.init)
            ?? viewModel.conversation.modelID
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            BeamView(intensity: viewModel.isGenerating ? 1 : 0.25)
                .frame(width: 240, height: 240)
            Text("Empieza una conversación")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(FaroColor.ash)
        }
    }

    private struct ModelLoadBand: View {
        let modelName: String
        let status: ModelLoadStatus

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(ModelLoadStatusFormatter.phaseLabel(status)) \(modelName)")
                        .font(.footnote)
                        .foregroundStyle(.white)
                    Spacer()
                    Text(ModelLoadStatusFormatter.line(status))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(FaroColor.ash)
                }
                ProgressView(value: status.fraction)
                    .tint(FaroColor.beamCore)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FaroColor.inkRaised, in: .rect(cornerRadius: 12))
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(viewModel.messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 90).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .onChange(of: viewModel.messages.last?.content) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.count) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}
