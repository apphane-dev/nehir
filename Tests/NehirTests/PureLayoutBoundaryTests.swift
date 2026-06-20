import Foundation
import Testing

@Suite struct PureLayoutBoundaryTests {
    @Test func pureLayoutFilesDoNotReferenceRuntimeOrPlatformTypes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Nehir/Core/PureLayout")

        let forbiddenTokens = [
            "import AppKit",
            "import ApplicationServices",
            "AXUIElement",
            "SkyLight",
            "WindowToken",
            "NiriNode",
            "NiriLayoutEngine",
            "ViewportState",
            "WorkspaceDescriptor",
            "Monitor.",
            "Monitor("
        ]

        let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" } ?? []

        #expect(!files.isEmpty)
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for token in forbiddenTokens {
                #expect(!content.contains(token), "\(file.lastPathComponent) contains forbidden token \(token)")
            }
        }
    }
}
