import SwiftUI

@MainActor
struct ChatView: View {
    @EnvironmentObject private var chat: ChatOrchestrator
    @State private var pressing = false

    var body: some View {
        VStack(spacing: 8) {
            conversation
            if !chat.metrics.isEmpty {
                Text(chat.metrics)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            controls
        }
        .padding(12)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(chat.chatLog) { message in
                        bubble(message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: chat.chatLog.last?.text) { _ in
                guard let id = chat.chatLog.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func bubble(_ message: ChatOrchestrator.Msg) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 44) }
            Text(message.text.isEmpty && message.role == "assistant" ? "…" : message.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(message.role == "user" ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(message.role == "user" ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 13))
            if message.role != "user" { Spacer(minLength: 44) }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Text(pressing ? "松开 · 结束" : (chat.busy ? "对话中" : "按住 · 说话"))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(chat.listening ? Color.red : (chat.busy ? Color.gray : Color.accentColor))
                .clipShape(Capsule())
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !pressing else { return }
                            pressing = true
                            chat.startMic()
                        }
                        .onEnded { _ in
                            pressing = false
                            chat.stopMicAndChat()
                        }
                )
                .opacity(chat.busy ? 0.6 : 1)

            Button("打断") { chat.abortTurn("已打断") }
                .buttonStyle(.bordered)
                .disabled(!chat.busy)
        }
    }
}
