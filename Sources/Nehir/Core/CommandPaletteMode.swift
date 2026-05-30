import Foundation

enum CommandPaletteMode: String, CaseIterable, Codable {
    case windows
    case menu

    var displayName: String {
        switch self {
        case .windows: "Windows"
        case .menu: "Menu"
        }
    }
}
