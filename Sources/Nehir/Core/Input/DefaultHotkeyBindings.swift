import Carbon

enum DefaultHotkeyBindings {
    static func all() -> [HotkeyBinding] {
        ActionCatalog.defaultHotkeyBindings()
    }
}
