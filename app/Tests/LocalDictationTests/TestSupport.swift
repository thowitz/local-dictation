import Foundation

enum TestSupport {
    /// Creates a unique temporary directory that is removed when `body` returns.
    static func withTemporaryDirectory<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDictationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    /// Writes an executable (or non-executable) file at `url` with optional contents.
    static func writeFile(
        at url: URL,
        contents: String = "#!/bin/sh\nexit 0\n",
        executable: Bool
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        } else {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
        }
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}
