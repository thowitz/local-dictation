import Foundation
import Testing
@testable import LocalDictation

@Suite("ServerDiagnostics")
struct ServerDiagnosticsTests {
    // MARK: - Bounded stderr collector

    @Test("LF and CR split into logical lines")
    func lfAndCRSplitIntoLogicalLines() {
        var collector = BoundedStderrCollector()
        collector.append(data: Data("one\ntwo\rthree\n".utf8))
        collector.flushEOF()
        #expect(collector.tail() == "one\ntwo\nthree")
    }

    @Test("Chunks split across boundaries reassemble")
    func chunksSplitAcrossBoundariesReassemble() {
        var collector = BoundedStderrCollector()
        collector.append(data: Data("hel".utf8))
        collector.append(data: Data("lo\nwor".utf8))
        collector.append(data: Data("ld\n".utf8))
        collector.flushEOF()
        #expect(collector.tail() == "hello\nworld")
    }

    @Test("Split UTF-8 sequences across chunks are preserved")
    func splitUTF8SequencesAcrossChunksArePreserved() throws {
        // U+00E9 (é) is C3 A9 in UTF-8 — split the two bytes across chunks.
        let bytes: [UInt8] = [0xC3, 0xA9]
        var collector = BoundedStderrCollector()
        collector.append(data: Data([bytes[0]]))
        collector.append(data: Data([bytes[1]]) + Data(" café\n".utf8))
        collector.flushEOF()
        #expect(collector.tail().contains("é"))
        #expect(collector.tail().contains("café") || collector.tail().contains("é café"))
    }

    @Test("Final partial line is flushed at EOF")
    func finalPartialLineIsFlushedAtEOF() {
        var collector = BoundedStderrCollector()
        collector.append(data: Data("no-newline-yet".utf8))
        #expect(collector.tail().isEmpty)
        collector.flushEOF()
        #expect(collector.tail() == "no-newline-yet")
    }

    @Test("Truncation enforces line and byte caps with marker")
    func truncationEnforcesCapsWithMarker() {
        var collector = BoundedStderrCollector()
        for i in 0..<80 {
            collector.append(data: Data("line-\(i)\n".utf8))
        }
        collector.flushEOF()
        let tail = collector.tail()
        #expect(tail.hasPrefix(BoundedStderrCollector.truncationMarker))
        let body = tail.replacingOccurrences(
            of: BoundedStderrCollector.truncationMarker + "\n",
            with: ""
        )
        let kept = body.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(kept.count <= BoundedStderrCollector.maxLines)
        #expect(tail.utf8.count <= BoundedStderrCollector.maxBytes + BoundedStderrCollector.truncationMarker.utf8.count + 1)
    }

    @Test("Attempt separators retain output across restarts")
    func attemptSeparatorsRetainOutputAcrossRestarts() {
        var collector = BoundedStderrCollector()
        collector.beginAttempt(1)
        collector.append(data: Data("first\n".utf8))
        collector.beginAttempt(2)
        collector.append(data: Data("second\n".utf8))
        collector.flushEOF()
        let tail = collector.tail()
        #expect(tail.contains("attempt 1"))
        #expect(tail.contains("first"))
        #expect(tail.contains("attempt 2"))
        #expect(tail.contains("second"))
    }

    @Test("Reset clears collector for a new supervision run")
    func resetClearsCollectorForNewRun() {
        var collector = BoundedStderrCollector()
        collector.append(data: Data("old\n".utf8))
        collector.flushEOF()
        collector.reset()
        #expect(collector.tail().isEmpty)
        #expect(collector.wasTruncated == false)
    }

    @Test("Invalid leading UTF-8 bytes do not block later output")
    func invalidLeadingUTF8BytesDoNotBlockLaterOutput() {
        var collector = BoundedStderrCollector()
        for _ in 0..<100 {
            collector.append(data: Data([0xFF]))
        }
        collector.append(data: Data("hello\n".utf8))
        collector.flushEOF()
        #expect(collector.tail().contains("hello"))
        #expect(collector.pendingUndecodedByteCount <= 3)
        #expect(collector.wasTruncated)
    }

    @Test("Pending line without newlines stays within byte cap")
    func pendingLineWithoutNewlinesStaysWithinByteCap() {
        var collector = BoundedStderrCollector()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 1024)
        for _ in 0..<100 {
            collector.append(data: chunk)
        }
        #expect(collector.storageByteEstimate <= BoundedStderrCollector.maxBytes + 64)
        #expect(collector.wasTruncated)
        collector.flushEOF()
        #expect(collector.storageByteEstimate <= BoundedStderrCollector.maxBytes + BoundedStderrCollector.truncationMarker.utf8.count + 64)
    }

    @Test("Large newline-free append stays bounded and linear")
    func largeNewlineFreeAppendStaysBoundedAndLinear() {
        let payload = Data(repeating: UInt8(ascii: "a"), count: 200 * 1024)

        var oneShot = BoundedStderrCollector()
        oneShot.append(data: payload)
        #expect(oneShot.storageByteEstimate <= BoundedStderrCollector.maxBytes + 64)
        #expect(oneShot.wasTruncated)
        #expect(oneShot.pendingUndecodedByteCount <= 3)
        oneShot.flushEOF()
        #expect(oneShot.storageByteEstimate <= BoundedStderrCollector.maxBytes + BoundedStderrCollector.truncationMarker.utf8.count + 64)

        var byteWise = BoundedStderrCollector()
        let unit = Data([UInt8(ascii: "b")])
        for _ in 0..<(200 * 1024) {
            byteWise.append(data: unit)
        }
        #expect(byteWise.storageByteEstimate <= BoundedStderrCollector.maxBytes + 64)
        #expect(byteWise.wasTruncated)
        #expect(byteWise.pendingUndecodedByteCount <= 3)
        byteWise.flushEOF()
        #expect(byteWise.storageByteEstimate <= BoundedStderrCollector.maxBytes + BoundedStderrCollector.truncationMarker.utf8.count + 64)
    }

    @Test("Oversize completed line does not erase prior tail")
    func oversizeCompletedLineDoesNotErasePriorTail() {
        var collector = BoundedStderrCollector()
        collector.append(data: Data("keep-me\n".utf8))
        let monster = String(repeating: "m", count: 9 * 1024) + "\n"
        collector.append(data: Data(monster.utf8))
        collector.flushEOF()
        #expect(collector.tail().contains("keep-me"))
        #expect(collector.wasTruncated)
    }

    @Test("CRLF does not insert empty logical lines")
    func crlfDoesNotInsertEmptyLogicalLines() {
        var collector = BoundedStderrCollector()
        collector.append(data: Data("a\r\nb\n".utf8))
        collector.flushEOF()
        #expect(collector.tail() == "a\nb")
    }

    // MARK: - Download progress parser

    @Test("HF tqdm lines produce known percent")
    func hfTqdmLinesProduceKnownPercent() {
        let line = "model.safetensors:  45%|████      | 1.57G/3.50G [00:10<00:12, 155MB/s]"
        let result = DownloadProgressParser.parse(line)
        #expect(result.isDownloadProgress)
        #expect(result.percent == 45)
        #expect(!result.percentUnknown)
    }

    @Test("Fetching files line produces known percent")
    func fetchingFilesLineProducesKnownPercent() {
        let line = "Fetching 12 files:  30%|███       | 3/12"
        let result = DownloadProgressParser.parse(line)
        #expect(result.isDownloadProgress)
        #expect(result.percent == 30)
    }

    @Test("HF download line with unknown percent")
    func hfDownloadLineWithUnknownPercent() {
        let line = "Fetching 12 files: |███       | downloading…"
        let result = DownloadProgressParser.parse(line)
        #expect(result.isDownloadProgress)
        #expect(result.percent == nil)
        #expect(result.percentUnknown)
    }

    @Test("CPU percent is not download progress")
    func cpuPercentIsNotDownloadProgress() {
        let result = DownloadProgressParser.parse("CPU 45%")
        #expect(!result.isDownloadProgress)
        #expect(result.percent == nil)
    }

    @Test("Resource meters with trailing junk are not download progress")
    func resourceMetersWithTrailingJunkAreNotDownloadProgress() {
        for line in ["Memory: 80%", "GPU 12%", "CPU 45% | extra"] {
            let result = DownloadProgressParser.parse(line)
            #expect(!result.isDownloadProgress, "Expected non-download for \(line)")
            #expect(result.percent == nil)
        }
    }

    @Test("Non-empty output is startup activity without downloading")
    func nonEmptyOutputIsStartupActivityWithoutDownloading() {
        #expect(DownloadProgressParser.isStartupActivity("loading weights…"))
        let result = DownloadProgressParser.parse("loading weights…")
        #expect(!result.isDownloadProgress)
    }

    @Test("Empty line is not startup activity")
    func emptyLineIsNotStartupActivity() {
        #expect(!DownloadProgressParser.isStartupActivity("   "))
    }

    // MARK: - Remediation

    @Test("Port collision remediation")
    func portCollisionRemediation() {
        let text = ServerRemediation.classify(
            kind: .portInUse,
            commandSource: .development,
            stderrTail: ""
        )
        #expect(text?.contains("port") == true)

        let fromStderr = ServerRemediation.classify(
            kind: .launchFailed,
            commandSource: .development,
            stderrTail: "LOCAL_DICTATION_FATAL kind=port_in_use EADDRINUSE"
        )
        #expect(fromStderr?.lowercased().contains("port") == true)
    }

    @Test("Import failure remediation differs by command source")
    func importFailureRemediationDiffersByCommandSource() {
        let dev = ServerRemediation.classify(
            kind: .launchFailed,
            commandSource: .development,
            stderrTail: "ModuleNotFoundError: No module named 'local_dictation_server'"
        )
        #expect(dev?.contains("uv sync") == true || dev?.contains("make server") == true)

        let bundled = ServerRemediation.classify(
            kind: .launchFailed,
            commandSource: .bundleHelper,
            stderrTail: "ModuleNotFoundError: No module named 'local_dictation_server'"
        )
        #expect(bundled?.lowercased().contains("reinstall") == true)
    }

    @Test("HF network failure remediation")
    func hfNetworkFailureRemediation() {
        let text = ServerRemediation.classify(
            kind: .readinessTimedOut,
            commandSource: .development,
            stderrTail: "huggingface_hub.errors.HfHubHTTPError: Connection error"
        )
        #expect(text?.contains("make model") == true)
    }

    @Test("Unknown errors have no guessed remediation")
    func unknownErrorsHaveNoGuessedRemediation() {
        let text = ServerRemediation.classify(
            kind: .consecutiveExits,
            commandSource: .development,
            stderrTail: "something mysterious happened"
        )
        #expect(text == nil)
    }

    // MARK: - Failure details

    @Test("Details include command source executable prefix port exit stderr")
    func detailsIncludeCommandFacts() {
        let command = ServerLaunchCommand(
            executableURL: URL(fileURLWithPath: "/opt/python3"),
            argumentPrefix: ServerLaunchCommand.bundleHelperArgumentPrefix,
            source: .bundleHelper
        )
        var collector = BoundedStderrCollector()
        for i in 0..<60 {
            collector.append(data: Data("err-\(i)\n".utf8))
        }
        collector.flushEOF()
        let failure = ServerFailure(
            kind: .readinessTimedOut,
            command: command,
            port: 8471,
            exit: ServerExit(
                reason: .timedOut,
                runDuration: .seconds(12),
                command: command,
                activity: StartupActivitySnapshot(
                    lastOutputAt: Date(timeIntervalSince1970: 1),
                    downloadPercent: 40,
                    downloadPercentUnknown: false,
                    lastDownloadProgressAt: Date(timeIntervalSince1970: 1)
                ),
                stderrTail: collector.tail(),
                port: 8471
            ),
            activity: StartupActivitySnapshot(
                lastOutputAt: Date(timeIntervalSince1970: 1),
                downloadPercent: 40,
                downloadPercentUnknown: false,
                lastDownloadProgressAt: Date(timeIntervalSince1970: 1)
            ),
            stderrTail: collector.tail(),
            underlyingMessage: nil
        )
        let details = failure.detailsText
        #expect(details.contains("bundleHelper"))
        #expect(details.contains("/opt/python3"))
        #expect(details.contains("-m"))
        #expect(details.contains("port: 8471"))
        #expect(details.contains("timed out") || details.contains("readiness"))
        #expect(details.contains("40%"))
        #expect(details.contains(BoundedStderrCollector.truncationMarker))
        #expect(details.contains("stderr:"))
    }
}
