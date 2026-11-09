import Foundation

enum AppText {
    static func sectionTitle(_ identifier: String) -> String {
        switch identifier {
        case "Container": String(localized: "Container")
        case "Images": String(localized: "Images")
        case "Volumes": String(localized: "Volumes")
        case "Netzwerke": String(localized: "Netzwerke")
        case "Mac-Freigaben": String(localized: "Mac-Freigaben")
        case "Befehle": String(localized: "Befehle")
        case "Runtime": String(localized: "Runtime")
        case "Backups": String(localized: "Backups")
        case "Builds": String(localized: "Builds")
        default: identifier
        }
    }
    static func creationTitle(_ identifier: String) -> String {
        switch identifier {
        case "Images": String(localized: "Image herunterladen")
        case "Volumes": String(localized: "Volume erstellen")
        case "Netzwerke": String(localized: "Netzwerk erstellen")
        default: String(localized: "Container erstellen")
        }
    }
    static func containerState(_ state: String) -> String {
        switch state {
        case "running": String(localized: "Läuft")
        case "created": String(localized: "Erstellt")
        case "exited": String(localized: "Beendet")
        case "paused": String(localized: "Pausiert")
        case "restarting": String(localized: "Wird neu gestartet")
        case "removing": String(localized: "Wird entfernt")
        case "dead": String(localized: "Defekt")
        default: state
        }
    }
}
