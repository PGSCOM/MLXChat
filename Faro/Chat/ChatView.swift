import SwiftUI

struct ChatView: View {
    @State var viewModel: ChatViewModel

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
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FaroColor.beamFar.opacity(0.4), in: .rect(cornerRadius: 12))
                    }
                    ComposerView(viewModel: viewModel)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .navigationTitle(viewModel.conversation.title)
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
