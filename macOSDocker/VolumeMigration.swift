import Foundation

struct VolumeMigration {
    static let image = "debian:bookworm-slim"
    static let copyScript = """
    set -euo pipefail
    test -z "$(ls -A /destination)"
    cp -a --preserve=mode,ownership,timestamps,links,xattr --sparse=always /source/. /destination/
    tar --create --sparse --numeric-owner --acls --xattrs --xattrs-include='*' -C /source . | tar --compare --numeric-owner --acls --xattrs --xattrs-include='*' -f - -C /destination
    sync
    """

    static func validate(source: String, destination: String) throws {
        guard destination != source else { throw AppFailure(message: String(localized: "Bitte einen anderen Volume-Namen eingeben.")) }
        guard destination.count <= 255,
              destination.range(of: "\\A[a-zA-Z0-9][a-zA-Z0-9_.-]+\\z", options: .regularExpression) != nil else {
            throw AppFailure(message: String(localized: "Volume-Namen benötigen 2–255 Zeichen: Buchstaben, Zahlen, Punkt, Unterstrich oder Bindestrich. Das erste Zeichen muss ein Buchstabe oder eine Zahl sein."))
        }
    }

    static func copyArguments(source: String, destination: String, helper: String) -> [String] {
        ["run", "--name", helper, "--network", "none", "--read-only",
         "--mount", "type=volume,source=\(source),target=/source,readonly,volume-nocopy",
         "--mount", "type=volume,source=\(destination),target=/destination,volume-nocopy",
         image, "bash", "-c", copyScript]
    }
}
