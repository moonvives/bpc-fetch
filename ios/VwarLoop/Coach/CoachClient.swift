import Foundation
import Security

/// Guarda a chave da API no Keychain do aparelho.
///
/// Nao vai para UserDefaults (que sai em backup em texto claro) nem para o
/// repositorio. Fica no Keychain com `ThisDeviceOnly`, entao nem migra para um
/// aparelho novo via backup.
enum KeychainStore {
    private static let service = "com.example.vwarloop.anthropic"
    private static let account = "api-key"

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        delete()
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var hasKey: Bool { load() != nil }
}

/// Cliente da Messages API da Anthropic.
///
/// Chamado direto do aparelho com a chave do proprio usuario. Nao ha backend
/// intermediario, entao nenhum dado de saude passa por servidor de terceiro alem
/// da propria Anthropic no momento da pergunta.
struct CoachClient {

    struct Message: Codable, Identifiable, Equatable {
        var id = UUID()
        var role: String   // "user" | "assistant"
        var content: String

        enum CodingKeys: String, CodingKey { case role, content }
    }

    enum CoachError: LocalizedError {
        case noKey, unauthorized, rateLimited, refused
        case server(Int), network(String), decoding

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "Nenhuma chave de API configurada. Adicione a sua chave da "
                     + "Anthropic em Ajustes."
            case .unauthorized:
                return "Chave de API inválida. Confira em Ajustes."
            case .rateLimited:
                return "Limite de requisições atingido. Tente de novo em instantes."
            case .refused:
                return "O modelo recusou responder a esta solicitação."
            case .server(let code):
                return "Erro do servidor da Anthropic (\(code)). Tente mais tarde."
            case .network(let detail):
                return "Falha de conexão: \(detail)"
            case .decoding:
                return "Resposta em formato inesperado."
            }
        }
    }

    static let systemPrompt = """
        Você é o coach pessoal de bem-estar do usuário dentro do app "VWAR Loop", \
        um app local-first e privado. Fale português do Brasil, de forma direta, \
        calorosa e prática — como um treinador que conhece o histórico da pessoa.

        Você recebe um resumo dos últimos ~30 dias (sono, FC de repouso, HRV, \
        SpO2, treinos, humor, energia, estresse, foco e um "Recovery Score" de 0 \
        a 100 calculado a partir de baselines pessoais), e também um painel de \
        INCERTEZA com a cobertura e a confiabilidade de cada métrica.

        Regras:

        - Olhe a incerteza antes de afirmar qualquer coisa. Se uma métrica tem \
        cobertura baixa, lacuna grande ou ainda não tem baseline, diga isso \
        explicitamente e calibre a confiança da recomendação. Nunca trate sinal \
        ruidoso como preciso.
        - Métricas derivadas de frequência cardíaca (scores de estresse, \
        "energia") não são evidência independente da própria FC. Não as some \
        como se fossem achados separados que se confirmam.
        - Fundamente cada observação em números concretos do resumo.
        - Você NÃO é profissional de saúde. Não diagnostique, não prescreva, não \
        interprete sintomas clínicos e não oriente sobre medicação — inclusive \
        sobre tomar, pular ou ajustar doses. Isso é de quem prescreve. Para \
        qualquer preocupação médica, oriente procurar um profissional.
        - Se aparecerem sintomas de alarme (dor no peito, falta de ar em repouso, \
        desmaio, palpitação irregular, FC de repouso sustentada acima de 120), \
        diga com clareza para procurar atendimento, sem dramatizar o resto.
        - A pulseira é uma banda barata com chipset JieLi JL7013A, sem validação \
        clínica. FC, HRV, SpO2, sono e passos são tendências úteis. IGNORE e \
        desencoraje confiar em "ácido úrico", "lipídios", "colesterol", "glicose" \
        e "pressão arterial" vindos dela: são estimativas de software sem base \
        científica. Se o usuário citar esses números, diga isso.
        - Evite linguagem catastrófica ("colapso", "seu corpo está se \
        consumindo"). Ela aumenta ansiedade, ansiedade aumenta a frequência \
        cardíaca, e a FC mais alta realimenta o próprio score — um ciclo que \
        parece confirmação e não é.
        - Seja acionável: 2 a 4 recomendações concretas ligadas aos dados.
        """

    func send(messages: [Message], context: String) async throws -> String {
        guard let apiKey = KeychainStore.load(), !apiKey.isEmpty else {
            throw CoachError.noKey
        }

        let body: [String: Any] = [
            "model": "claude-opus-4-8",
            "max_tokens": 16_000,
            "thinking": ["type": "adaptive"],
            "system": Self.systemPrompt
                + "\n\n### Resumo e incerteza dos dados\n" + context,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CoachError.network(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 403: throw CoachError.unauthorized
        case 429: throw CoachError.rateLimited
        default: throw CoachError.server(status)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CoachError.decoding }

        // Sempre cheque stop_reason antes de ler content: numa recusa o array
        // pode vir vazio, e indexar content[0] estoura.
        if json["stop_reason"] as? String == "refusal" { throw CoachError.refused }

        guard let blocks = json["content"] as? [[String: Any]] else {
            throw CoachError.decoding
        }
        // Blocos de thinking tambem chegam no array; só o texto interessa aqui.
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        guard !text.isEmpty else { throw CoachError.decoding }
        return text
    }
}
