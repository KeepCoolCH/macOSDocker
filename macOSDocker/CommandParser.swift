import Foundation

enum CommandWords {
    static func parse(_ input: String, directory: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> [String] {
        let characters = Array(input.replacingOccurrences(of: "\r\n", with: "\n"))
        var words: [String] = [], word = "", started = false, quote: Character?, index = 0
        func finish() { if started { words.append(word); word = ""; started = false } }
        while index < characters.count {
            let char = characters[index]
            if quote == "'" {
                if char == "'" { quote = nil } else { word.append(char) }
                index += 1; continue
            }
            if char == "\\" {
                guard index + 1 < characters.count else { throw AppFailure(message: String(localized: "Unvollständiger Backslash am Ende des Befehls.")) }
                let next = characters[index + 1]
                if next == "\n" { index += 2; continue }
                if quote == "\"", !["$", "`", "\"", "\\"].contains(next) { word.append(char); index += 1; continue }
                word.append(next); started = true; index += 2; continue
            }
            if char == "\"" { quote = quote == "\"" ? nil : "\""; started = true; index += 1; continue }
            if quote == nil && char == "'" { quote = "'"; started = true; index += 1; continue }
            if char == "`" { throw AppFailure(message: String(localized: "Shell-Auswertung mit Backticks wird nicht unterstützt. Bitte einen konkreten Pfad verwenden.")) }
            if char == "$" {
                let remainder = String(characters[index...])
                let values = [("$(pwd)", directory.path), ("${PWD}", directory.path), ("${HOME}", home)]
                if let value = values.first(where: { remainder.hasPrefix($0.0) }) {
                    word += value.1; started = true; index += value.0.count; continue
                }
                if remainder.hasPrefix("$(") { throw AppFailure(message: String(localized: "Nur $(pwd) ist als Befehlsersetzung unterstützt. Andere Shell-Befehle bitte im Terminal ausführen.")) }
                var end = index + 1
                while end < characters.count && (characters[end].isLetter || characters[end].isNumber || characters[end] == "_") { end += 1 }
                let variable = String(characters[(index+1)..<end])
                if variable == "HOME" || variable == "PWD" { word += variable == "HOME" ? home : directory.path; index = end; started = true; continue }
                throw AppFailure(message: String(localized: "Nicht unterstützte Shell-Variable. $HOME, $PWD und $(pwd) sind möglich; literale Dollarzeichen in einfache Anführungszeichen setzen."))
            }
            if quote == nil {
                if char.isWhitespace { finish(); index += 1; continue }
                if ";|&<>".contains(char) { throw AppFailure(message: String(localized: "Bitte genau einen Docker-Befehl ohne Pipes, Umleitungen oder verkettete Shell-Befehle eingeben.")) }
                if char == "#" && !started {
                    while index < characters.count && characters[index] != "\n" { index += 1 }
                    continue
                }
                if char == "~" && !started && (index + 1 == characters.count || characters[index+1] == "/") { word += home; started = true; index += 1; continue }
            }
            word.append(char); started = true; index += 1
        }
        guard quote == nil else { throw AppFailure(message: String(localized: "Ein Anführungszeichen ist nicht geschlossen.")) }
        finish()
        guard !words.isEmpty else { throw AppFailure(message: String(localized: "Bitte einen Docker-Befehl eingeben.")) }
        return words
    }
}

struct CLIOptions {
    struct Option { let long: String; let takesValue: Bool }
    var definitions: [String: Option] = [:]
    init(help: String) {
        let regex = try! NSRegularExpression(pattern: #"^\s*(?:-([A-Za-z]),\s*)?--([a-z0-9-]+)(?: ([a-zA-Z0-9-]+))?\s{2,}"#)
        for line in help.components(separatedBy: "\n") {
            let text = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { continue }
            let long = text.substring(with: match.range(at: 2))
            let option = Option(long: long, takesValue: match.range(at: 3).location != NSNotFound)
            definitions["--" + long] = option
            if match.range(at: 1).location != NSNotFound { definitions["-" + text.substring(with: match.range(at: 1))] = option }
        }
    }

    struct Parsed { var options: [(String, String?)] = []; var remainder: [String] = [] }
    func parse(_ words: [String]) throws -> Parsed {
        var parsed = Parsed(), index = 0
        while index < words.count {
            let word = words[index]
            if word == "--" { index += 1; break }
            if !word.hasPrefix("-") || word == "-" { break }
            if word.hasPrefix("--") {
                let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let option = definitions[parts[0]] else { throw AppFailure(message: String(localized: "Unbekannte Option: \(parts[0])")) }
                var value = parts.count == 2 ? parts[1] : nil
                if option.takesValue && value == nil {
                    index += 1
                    guard index < words.count else { throw AppFailure(message: String(localized: "Wert für \(parts[0]) fehlt.")) }
                    value = words[index]
                }
                parsed.options.append((option.long, value))
            } else {
                let flags = Array(word.dropFirst())
                var shortIndex = 0
                while shortIndex < flags.count {
                    let key = "-" + String(flags[shortIndex])
                    guard let option = definitions[key] else { throw AppFailure(message: String(localized: "Unbekannte Option: \(key)")) }
                    var value: String?
                    if option.takesValue {
                        if shortIndex + 1 < flags.count { value = String(flags[(shortIndex+1)...]); if value!.hasPrefix("=") { value!.removeFirst() } }
                        else { index += 1; guard index < words.count else { throw AppFailure(message: String(localized: "Wert für \(key) fehlt.")) }; value = words[index] }
                        shortIndex = flags.count
                    } else if shortIndex + 1 < flags.count && flags[shortIndex+1] == "=" {
                        value = String(flags[(shortIndex+2)...]); shortIndex = flags.count
                    } else { shortIndex += 1 }
                    parsed.options.append((option.long, value))
                }
            }
            index += 1
        }
        parsed.remainder = Array(words.dropFirst(index))
        return parsed
    }
    static func arguments(_ options: [(String, String?)]) -> [String] {
        options.map { "--" + $0.0 + ($0.1.map { "=" + $0 } ?? "") }
    }
}

struct BindRequirement: Equatable, Codable, Sendable {
    let source: String
    let readOnly: Bool
}
struct PreparedRun {
    let arguments: [String]
    let binds: [BindRequirement]
    let interactive: Bool
}

enum DockerRunParser {
    static func prepare(_ text: String, directory: URL, help: String) throws -> PreparedRun {
        try prepare(arguments: CommandWords.parse(text, directory: directory), directory: directory, help: help)
    }

    static func prepare(arguments: [String], directory: URL, help: String) throws -> PreparedRun {
        var words = arguments
        guard words.first == "docker" || (words.first?.hasPrefix("/") == true && URL(fileURLWithPath: words[0]).lastPathComponent == "docker") else { throw AppFailure(message: String(localized: "Der Befehl muss mit docker run beginnen.")) }
        words.removeFirst()
        if words.first == "container" { words.removeFirst() }
        guard words.first == "run" else { throw AppFailure(message: String(localized: "Hier ist docker run vorgesehen. Compose hat einen eigenen Eingabemodus.")) }
        words.removeFirst()
        var parsed = try CLIOptions(help: help).parse(words)
        guard !parsed.remainder.isEmpty else { throw AppFailure(message: String(localized: "Das Container-Image fehlt.")) }
        var binds: [BindRequirement] = []
        for index in parsed.options.indices {
            let (name, value) = parsed.options[index]
            if name == "volume", let value {
                var parts = value.components(separatedBy: ":")
                if parts.count >= 2, isHostPath(parts[0]) {
                    parts[0] = resolve(parts[0], directory: directory)
                    let readOnly = parts.count > 2 && parts[2].split(separator: ",").contains("ro")
                    binds.append(BindRequirement(source: parts[0], readOnly: readOnly))
                    parsed.options[index].1 = parts.joined(separator: ":")
                }
            }
            if name == "mount", let value {
                var fields = try csv(value)
                let entries = fields.map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init) }
                let type = entries.first { $0.first == "type" }?.last ?? "volume"
                if type == "bind" {
                    guard let sourceIndex = entries.firstIndex(where: { ["src", "source"].contains($0[0]) }), entries[sourceIndex].count == 2 else { throw AppFailure(message: String(localized: "Quelle in --mount type=bind fehlt.")) }
                    let path = resolve(entries[sourceIndex][1], directory: directory)
                    fields[sourceIndex] = entries[sourceIndex][0] + "=" + path
                    let readOnly = entries.contains { ["ro", "readonly", "read-only"].contains($0[0]) && ($0.count == 1 || $0[1] != "false") }
                    binds.append(BindRequirement(source: path, readOnly: readOnly))
                    parsed.options[index].1 = fields.map { $0.contains(",") || $0.contains("\"") ? "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : $0 }.joined(separator: ",")
                }
            }
        }
        let interactive = parsed.options.contains { ["interactive", "tty"].contains($0.0) && $0.1 != "false" }
        return PreparedRun(arguments: ["run"] + CLIOptions.arguments(parsed.options) + parsed.remainder, binds: binds, interactive: interactive)
    }
    static func isHostPath(_ path: String) -> Bool { path.hasPrefix("/") || path.hasPrefix(".") || path.hasPrefix("~/") }
    static func resolve(_ path: String, directory: URL) -> String {
        if ["/var/run/docker.sock", "/run/docker.sock"].contains(path) { return path }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true)).standardizedFileURL
        if expanded.hasPrefix("/"), !url.path.hasPrefix("/Users/"), !url.path.hasPrefix("/Volumes/") { return url.path }
        return url.resolvingSymlinksInPath().path
    }
    private static func csv(_ value: String) throws -> [String] {
        let chars = Array(value)
        var fields: [String] = [], field = "", quoted = false, i = 0
        while i < chars.count {
            if chars[i] == "\"" {
                if quoted && i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 2; continue }
                quoted.toggle()
            } else if chars[i] == "," && !quoted { fields.append(field); field = "" }
            else { field.append(chars[i]) }
            i += 1
        }
        guard !quoted else { throw AppFailure(message: String(localized: "Ungültige Anführungszeichen im --mount-Argument.")) }
        fields.append(field)
        return fields
    }
}
