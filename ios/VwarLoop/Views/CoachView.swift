import SwiftUI

/// Coach de IA. Roda sob a chave de API do próprio usuário.
///
/// O prompt sempre carrega o painel de incerteza junto dos números, para que o
/// modelo diga o quanto confiar em cada afirmação em vez de tratar 2 dias de
/// dados com a mesma segurança de 28.
struct CoachView: View {
    let entries: [DailyEntry]
    let sleepGoal: Double

    @State private var messages: [CoachClient.Message] = []
    @State private var draft = ""
    @State private var isSending = false
    @State private var errorText: String?
    @FocusState private var inputFocused: Bool

    private let client = CoachClient()

    private let suggestions = [
        "Como está minha recuperação?",
        "Quais são meus melhores horários para treinar?",
        "O que está afetando meu foco?",
        "Em quais métricas eu ainda não deveria confiar?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            intro
                            ForEach(messages) { message in
                                bubble(message).id(message.id)
                            }
                            if isSending {
                                Text("Pensando...")
                                    .font(.subheadline).foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let errorText {
                                Text(errorText)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.critical)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.critical.opacity(0.12),
                                                in: RoundedRectangle(cornerRadius: 12))
                            }
                            if messages.isEmpty { suggestionChips }
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                    }
                }

                composer
            }
            .background(Theme.bg)
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var intro: some View {
        Card {
            Text("Este coach lê o resumo dos seus últimos 30 dias junto com o "
               + "painel de incerteza, e calibra o quanto afirma. Ele não "
               + "diagnostica, não orienta sobre medicação e ignora as "
               + "estimativas de glicose, ácido úrico, lipídios e pressão "
               + "arterial da pulseira.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(suggestions, id: \.self) { text in
                Button {
                    draft = text
                    send()
                } label: {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceAlt,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Theme.line, lineWidth: 1))
                }
            }
        }
    }

    private func bubble(_ message: CoachClient.Message) -> some View {
        let isUser = message.role == "user"
        return Text(message.content)
            .font(.subheadline)
            .foregroundStyle(isUser ? .white : Theme.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(isUser ? Theme.accent : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isUser ? .clear : Theme.line, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Escreva sua pergunta...", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.line, lineWidth: 1))
                .focused($inputFocused)

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Theme.accent : Theme.muted)
            }
            .disabled(!canSend)
        }
        .padding(12)
        .background(Theme.bg)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        errorText = nil
        inputFocused = false
        messages.append(.init(role: "user", content: text))
        isSending = true

        let context = EntryStore.coachContext(entries, sleepGoal: sleepGoal)
        let history = messages

        Task {
            do {
                let reply = try await client.send(messages: history, context: context)
                messages.append(.init(role: "assistant", content: reply))
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isSending = false
        }
    }
}
