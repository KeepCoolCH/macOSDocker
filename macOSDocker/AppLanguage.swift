import Foundation
import Combine

@MainActor
final class AppLanguage: ObservableObject {
    @Published private(set) var selection: String
    @Published var restartRequired = false
    private let launchSelection: String

    init() {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        let languages = domain?["AppleLanguages"] as? [String]
        let code = languages?.first?.split(separator: "-").first.map(String.init)
        let selected = ["de", "en"].contains(code ?? "") ? code! : "system"
        selection = selected
        launchSelection = selected
    }

    func select(_ language: String) {
        guard ["system", "de", "en"].contains(language) else { return }
        if language == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([language], forKey: "AppleLanguages") }
        selection = language
        restartRequired = language != launchSelection
    }
}
