import SwiftData
import SwiftUI

/// VWAR Loop — app pessoal de observacao de vida.
///
/// Local-first: todo dado vive num store SwiftData no proprio aparelho. Nao ha
/// servidor, conta ou telemetria. O coach de IA e opcional e roda sob a chave de
/// API do proprio usuario, guardada no Keychain.
@main
struct VwarLoopApp: App {
    /// Container SwiftData. Se a migracao falhar (schema mudou entre versoes
    /// durante o desenvolvimento), cai para um store em memoria em vez de
    /// derrubar o app — o usuario perde o historico, mas consegue abrir e
    /// reimportar o backup.
    private let container: ModelContainer = {
        let schema = Schema([DailyEntry.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: fallback)
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}
