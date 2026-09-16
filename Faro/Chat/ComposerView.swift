import SwiftUI

struct ComposerView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Pregunta lo que quieras", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(FaroColor.inkRaised, in: .rect(cornerRadius: 18))
                .focused($focused)
                .onSubmit(send)

            Button {
                if viewModel.isGenerating { viewModel.cancel() } else { send() }
            } label: {
                Image(systemName: viewModel.isGenerating ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FaroColor.ink)
                    .frame(width: 34, height: 34)
                    .background(
                        (viewModel.isGenerating || !viewModel.draft.isEmpty)
                            ? FaroColor.beamCore : FaroColor.ash.opacity(0.3),
                        in: .circle
                    )
            }
            .disabled(!viewModel.isGenerating && viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send() {
        guard !viewModel.isGenerating else { return }
        viewModel.send()
    }
}
