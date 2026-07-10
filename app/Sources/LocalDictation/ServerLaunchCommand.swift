import Foundation

/// Where a resolved server launch command came from.
enum ServerLaunchCommandSource: String, Equatable, Sendable, CustomStringConvertible {
    case override
    case bundleHelper
    case applicationSupport
    case development

    var description: String { rawValue }
}

/// Executable + argument prefix used to launch the speech-runtime server.
struct ServerLaunchCommand: Equatable, Sendable {
    let executableURL: URL
    let argumentPrefix: [String]
    let source: ServerLaunchCommandSource

    /// Exact prefix for the packaged isolated Python helper (#5).
    static let bundleHelperArgumentPrefix = ["-I", "-B", "-u", "-m", "local_dictation_server.server"]

    /// Human-readable invocation: `executable [prefix…]`.
    var displayCommandLine: String {
        ([executableURL.path] + argumentPrefix)
            .map(Self.shellEscape)
            .joined(separator: " ")
    }

    /// Multi-line detail block for diagnostics / copy.
    var detailDescription: String {
        """
        source: \(source)
        executable: \(executableURL.path)
        argumentPrefix: \(argumentPrefix.isEmpty ? "(none)" : argumentPrefix.joined(separator: " "))
        """
    }

    /// Assembles Process arguments: prefix, then `--port` / `--parent-pid`, then optional `--model`.
    static func processArguments(
        prefix: [String],
        port: Int,
        parentPID: Int32,
        model: String?
    ) -> [String] {
        var args = prefix
        args += ["--port", "\(port)", "--parent-pid", "\(parentPID)"]
        if let model, !model.isEmpty {
            args += ["--model", model]
        }
        return args
    }

    func processArguments(port: Int, parentPID: Int32, model: String?) -> [String] {
        Self.processArguments(
            prefix: argumentPrefix,
            port: port,
            parentPID: parentPID,
            model: model
        )
    }

    private static func shellEscape(_ token: String) -> String {
        if token.isEmpty { return "''" }
        if token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@")).contains($0) }) {
            return token
        }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
