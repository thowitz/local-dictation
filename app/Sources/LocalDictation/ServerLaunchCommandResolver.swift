import Foundation

/// Resolves a `ServerLaunchCommand` using strict precedence (plan §2.3).
///
/// All filesystem and path inputs are injectable so tests never depend on cwd
/// or compiled-in absolute paths.
struct ServerLaunchCommandResolver: Sendable {
    struct AttemptedCandidate: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case missing
            case notExecutable
            case selected
        }

        let url: URL
        let source: ServerLaunchCommandSource
        let status: Status
    }

    enum ResolutionError: Error, Equatable, CustomStringConvertible {
        case overrideMissing(path: String)
        case overrideNotExecutable(path: String)
        case overrideNotAbsolute(path: String)
        case noCandidateFound(attempted: [AttemptedCandidate])

        var description: String {
            switch self {
            case .overrideMissing(let path):
                return "Configured serverExecutable is missing: \(path)"
            case .overrideNotExecutable(let path):
                return "Configured serverExecutable is not executable: \(path)"
            case .overrideNotAbsolute(let path):
                return "Configured serverExecutable must be an absolute path after ~ expansion: \(path)"
            case .noCandidateFound(let attempted):
                let lines = attempted.map { candidate in
                    let status: String
                    switch candidate.status {
                    case .missing: status = "missing"
                    case .notExecutable: status = "not executable"
                    case .selected: status = "selected"
                    }
                    return "- [\(candidate.source)] \(candidate.url.path) (\(status))"
                }
                return """
                No server launch command found. Attempted:
                \(lines.joined(separator: "\n"))
                """
            }
        }

        var attemptedCandidates: [AttemptedCandidate] {
            switch self {
            case .overrideMissing, .overrideNotExecutable, .overrideNotAbsolute:
                return []
            case .noCandidateFound(let attempted):
                return attempted
            }
        }
    }

    typealias FileExists = @Sendable (URL) -> Bool
    typealias IsExecutable = @Sendable (URL) -> Bool

    let executableURL: URL
    let homeDirectoryURL: URL
    let supportDirectoryURL: URL
    let fileExists: FileExists
    let isExecutable: IsExecutable
    let maxAncestorDepth: Int

    init(
        executableURL: URL,
        homeDirectoryURL: URL,
        supportDirectoryURL: URL,
        fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0.path) },
        isExecutable: @escaping IsExecutable = { FileManager.default.isExecutableFile(atPath: $0.path) },
        maxAncestorDepth: Int = 12
    ) {
        self.executableURL = executableURL
        self.homeDirectoryURL = homeDirectoryURL
        self.supportDirectoryURL = supportDirectoryURL
        self.fileExists = fileExists
        self.isExecutable = isExecutable
        self.maxAncestorDepth = maxAncestorDepth
    }

    func resolve(override: String?) -> Result<ServerLaunchCommand, ResolutionError> {
        if let override, !override.isEmpty {
            return resolveOverride(override)
        }

        var attempted: [AttemptedCandidate] = []

        if let command = resolveBundleHelper(attempted: &attempted) {
            return .success(command)
        }

        // Packaged context: a missing/broken helper is terminal — do not fall through
        // to Application Support or a nearby development checkout.
        if contentsDirectory(from: executableURL) != nil {
            return .failure(.noCandidateFound(attempted: attempted))
        }

        if let command = resolveApplicationSupport(attempted: &attempted) {
            return .success(command)
        }
        if let command = resolveDevelopment(attempted: &attempted) {
            return .success(command)
        }

        return .failure(.noCandidateFound(attempted: attempted))
    }

    // MARK: - Precedence steps

    private func resolveOverride(_ raw: String) -> Result<ServerLaunchCommand, ResolutionError> {
        let expanded = expandTilde(in: raw)
        guard expanded.hasPrefix("/") else {
            return .failure(.overrideNotAbsolute(path: expanded))
        }
        let url = URL(fileURLWithPath: expanded)
        if !fileExists(url) {
            return .failure(.overrideMissing(path: url.path))
        }
        if !isExecutable(url) {
            return .failure(.overrideNotExecutable(path: url.path))
        }
        return .success(
            ServerLaunchCommand(
                executableURL: url,
                argumentPrefix: [],
                source: .override
            )
        )
    }

    private func resolveBundleHelper(attempted: inout [AttemptedCandidate]) -> ServerLaunchCommand? {
        guard let contentsURL = contentsDirectory(from: executableURL) else {
            return nil
        }
        let helper = contentsURL
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("LocalDictationServer", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3", isDirectory: false)

        return selectIfExecutable(
            helper,
            source: .bundleHelper,
            prefix: ServerLaunchCommand.bundleHelperArgumentPrefix,
            attempted: &attempted
        )
    }

    private func resolveApplicationSupport(attempted: inout [AttemptedCandidate]) -> ServerLaunchCommand? {
        let candidates = [
            supportDirectoryURL
                .appendingPathComponent("server/bin/local-dictation-serve", isDirectory: false),
            supportDirectoryURL
                .appendingPathComponent("server/.venv/bin/local-dictation-serve", isDirectory: false),
        ]
        for candidate in candidates {
            if let command = selectIfExecutable(
                candidate,
                source: .applicationSupport,
                prefix: [],
                attempted: &attempted
            ) {
                return command
            }
        }
        return nil
    }

    private func resolveDevelopment(attempted: inout [AttemptedCandidate]) -> ServerLaunchCommand? {
        guard let repoRoot = findRepositoryRoot(startingFrom: executableURL) else {
            return nil
        }
        let serve = repoRoot
            .appendingPathComponent("server/.venv/bin/local-dictation-serve", isDirectory: false)
        return selectIfExecutable(
            serve,
            source: .development,
            prefix: [],
            attempted: &attempted
        )
    }

    // MARK: - Helpers

    private func selectIfExecutable(
        _ url: URL,
        source: ServerLaunchCommandSource,
        prefix: [String],
        attempted: inout [AttemptedCandidate]
    ) -> ServerLaunchCommand? {
        if !fileExists(url) {
            attempted.append(AttemptedCandidate(url: url, source: source, status: .missing))
            return nil
        }
        if !isExecutable(url) {
            attempted.append(AttemptedCandidate(url: url, source: source, status: .notExecutable))
            return nil
        }
        attempted.append(AttemptedCandidate(url: url, source: source, status: .selected))
        return ServerLaunchCommand(executableURL: url, argumentPrefix: prefix, source: source)
    }

    /// Derive `…/Contents` from a running `…/Contents/MacOS/<name>` executable URL.
    private func contentsDirectory(from executable: URL) -> URL? {
        let macos = executable.deletingLastPathComponent()
        guard macos.lastPathComponent == "MacOS" else { return nil }
        let contents = macos.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        return contents
    }

    /// Bounded ancestor walk. Repo root is identified by BOTH `app/Package.swift`
    /// and `server/pyproject.toml`. Supports `.build/<triple>/debug|release` and
    /// `.build/debug|release` layouts at arbitrary clone roots.
    private func findRepositoryRoot(startingFrom executable: URL) -> URL? {
        var current = executable.deletingLastPathComponent().standardizedFileURL
        for _ in 0..<maxAncestorDepth {
            let packageSwift = current.appendingPathComponent("app/Package.swift")
            let pyproject = current.appendingPathComponent("server/pyproject.toml")
            if fileExists(packageSwift) && fileExists(pyproject) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private func expandTilde(in path: String) -> String {
        if path == "~" {
            return homeDirectoryURL.path
        }
        if path.hasPrefix("~/") {
            return homeDirectoryURL.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }
}
