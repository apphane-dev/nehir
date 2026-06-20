// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import CoreGraphics

struct MonitorOrientationSettings: MonitorSettingsType {
    var id: String {
        monitorDisplayId.map(String.init) ?? monitorName
    }

    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID? = nil
    var monitorAnchorPoint: CGPoint? = nil
    var orientation: Monitor.Orientation?
}
