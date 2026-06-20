// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import TOML

// Only file in Nehir that imports TOML — keep this boundary so swift-toml stays swappable.
enum SettingsTOMLCodec {
    static func encode(_ export: SettingsExport) throws -> Data {
        let canonical = CanonicalTOMLConfig(export: export)
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(canonical)
    }

    static func decode(_ data: Data) throws -> SettingsExport {
        let canonical = try TOMLDecoder().decode(CanonicalTOMLConfig.self, from: data)
        return canonical.toSettingsExport()
    }
}
