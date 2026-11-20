import AppKit
import ApplicationServices
import Darwin
import Foundation

struct GitRepositoryContext: Equatable, Sendable {
    let repositoryName: String
    let branchName: String?
    let issueKeys: [String]
    let activeFileNames: [String]
}

struct DictationContextSnapshot: Equatable, Sendable {
    let appName: String
    let bundleIdentifier: String?
    let windowTitle: String?
    let documentPath: String?
    let precedingText: String?
    let terminalTail: String?
    let recentTranscription: String?
    var gitContext: GitRepositoryContext?

    init(
        appName: String,
        bundleIdentifier: String?,
        windowTitle: String?,
        documentPath: String?,
        precedingText: String?,
        terminalTail: String? = nil,
        recentTranscription: String?,
        gitContext: GitRepositoryContext?
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.documentPath = documentPath
        self.precedingText = precedingText
        self.terminalTail = terminalTail
        self.recentTranscription = recentTranscription
        self.gitContext = gitContext
    }
}

@MainActor
protocol DictationContextProviding: AnyObject {
    func captureImmediateContext(
        for target: TargetApplication,
        recentTranscription: String?
    ) -> DictationContextSnapshot
    func enrichContext(
        _ snapshot: DictationContextSnapshot,
        target: TargetApplication
    ) async -> DictationContextSnapshot
}

enum DictationContextComposer {
    private static let ignoredKeyPrefixes: Set<String> = [
        "AES", "ARM", "BASE", "COVID", "CVE", "DDR", "ECDSA", "ESP", "GPT",
        "HDMI", "HTTP", "HTTPS", "IEEE", "ISO", "MD", "PKCS", "RFC", "RSA",
        "SHA", "SSL", "STM", "TLS", "USB", "UTC", "UTF", "WPA", "X86"
    ]

    static func composePrompt(
        basePrompt: String,
        learnedHints: [String] = [],
        context: DictationContextSnapshot?
    ) -> String {
        var sections: [String] = []
        let trimmedBase = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBase.isEmpty {
            sections.append(trimmedBase)
        }
        if let formattedHints = formatLearnedHints(learnedHints) {
            sections.append(formattedHints)
        }
        if let context, let formattedContext = formatContext(context) {
            sections.append(formattedContext)
        }
        return sections.joined(separator: "\n\n")
    }

    /// Formats learned hints cleanly on whole-hint boundaries (never slicing mid-word)
    /// so saved hints accumulate cleanly up to the budget.
    static func formatLearnedHints(_ hints: [String], maxLength: Int = 700) -> String? {
        let cleaned = hints
            .map { SecretRedactor.redact(sanitize($0, limit: 85)) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }

        let prefix = "Learned vocabulary hints: "
        var included: [String] = []
        var totalLength = prefix.count + 1 // trailing period
        for hint in cleaned {
            let separatorLength = included.isEmpty ? 0 : 2 // "; "
            if totalLength + separatorLength + hint.count > maxLength {
                break
            }
            included.append(hint)
            totalLength += separatorLength + hint.count
        }
        guard !included.isEmpty else { return nil }
        return prefix + included.joined(separator: "; ") + "."
    }

    static func formatContext(
        _ context: DictationContextSnapshot,
        maxLength: Int = 440
    ) -> String? {
        var parts: [String] = []

        if !context.appName.isEmpty {
            parts.append("App: \(sanitize(context.appName, limit: 40))")
        }

        if let title = context.windowTitle.map({ sanitize($0, limit: 90) }), !title.isEmpty {
            parts.append("Window: \(title)")
        }

        if let git = context.gitContext, !git.repositoryName.isEmpty {
            var repoSegment = "Repo: \(sanitize(git.repositoryName, limit: 40))"
            if let branch = git.branchName,
               !branch.isEmpty,
               branch != "HEAD",
               branch != "main",
               branch != "master" {
                repoSegment += " (branch: \(sanitize(branch, limit: 60)))"
            }
            parts.append(repoSegment)
        } else if let docPath = context.documentPath {
            let docName = URL(fileURLWithPath: docPath).lastPathComponent
            if !docName.isEmpty {
                parts.append("Document: \(sanitize(docName, limit: 50))")
            }
        }

        // Combine issue keys from terminal output, window title, git/svn branch,
        // recent commits, and project docs so project keys like TRXLINK / TRXTQI
        // are always prominent with explicit spelling guidance.
        var issueSources: [String] = []
        if let terminalTail = context.terminalTail { issueSources.append(terminalTail) }
        if let title = context.windowTitle { issueSources.append(title) }
        if let git = context.gitContext {
            if let branch = git.branchName { issueSources.append(branch) }
            issueSources.append(contentsOf: git.issueKeys)
        }
        if let preceding = context.precedingText { issueSources.append(preceding) }
        let issueKeys = extractIssueKeys(from: issueSources, limit: 6)
        if !issueKeys.isEmpty {
            parts.append("Prefer exact spellings for these Jira/issue keys (do not split into words): \(issueKeys.joined(separator: ", "))")
        }

        if let files = context.gitContext?.activeFileNames, !files.isEmpty {
            let fileList = files.prefix(8).map { sanitize($0, limit: 40) }.joined(separator: ", ")
            parts.append("Active files: \(fileList)")
        }

        if let preceding = context.precedingText.map({ sanitize($0, limit: 160) }), !preceding.isEmpty {
            parts.append("Text before cursor: \"\(preceding)\"")
        } else if let recent = context.recentTranscription.map({ sanitize($0, limit: 120) }), !recent.isEmpty {
            parts.append("Recent dictation: \"\(recent)\"")
        }

        guard !parts.isEmpty else { return nil }
        let raw = "Current context: " + parts.joined(separator: ". ") + "."
        let redacted = SecretRedactor.redact(raw)
        guard redacted.count > maxLength else { return redacted }
        return String(redacted.prefix(maxLength - 1)) + "…"
    }

    /// Extracts Jira/Linear-style issue keys (e.g. `TRXLINK-1420`) and their project prefixes
    /// (e.g. `TRXLINK`), preserving order of first appearance while excluding common technical
    /// identifiers such as `UTF-8` or `SHA-256`.
    static func extractIssueKeys(from texts: [String], limit: Int = 4) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9]{1,9})-(\d{1,6})\b"#) else {
            return []
        }

        var prefixes: [String] = []
        var fullKeys: [String] = []
        var seenPrefixes: Set<String> = []
        var seenFullKeys: Set<String> = []

        for text in texts {
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            for match in regex.matches(in: text, range: range) {
                let prefix = nsText.substring(with: match.range(at: 1))
                guard !ignoredKeyPrefixes.contains(prefix) else { continue }
                let full = nsText.substring(with: match.range)
                if seenPrefixes.insert(prefix).inserted {
                    prefixes.append(prefix)
                }
                if seenFullKeys.insert(full).inserted {
                    fullKeys.append(full)
                }
            }
        }

        var combined: [String] = []
        for prefix in prefixes where combined.count < limit {
            combined.append(prefix)
        }
        for key in fullKeys where combined.count < limit {
            combined.append(key)
        }
        return combined
    }

    static func extractPrecedingText(
        value: String,
        selectedLocation: Int,
        maxLength: Int = 180
    ) -> String? {
        let nsValue = value as NSString
        guard nsValue.length > 0, selectedLocation > 0 else { return nil }
        let clampedEnd = min(selectedLocation, nsValue.length)
        let start = max(0, clampedEnd - maxLength)
        var slice = nsValue.substring(with: NSRange(location: start, length: clampedEnd - start))
        if start > 0, let firstBreak = slice.rangeOfCharacter(from: .whitespacesAndNewlines) {
            slice = String(slice[firstBreak.upperBound...])
        }
        let cleaned = slice
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(2)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func extractDirectoryPath(
        documentAttribute: String?,
        windowTitle: String?,
        fileManager: FileManager = .default
    ) -> String? {
        if let documentAttribute, let path = resolveExistingDirectory(from: documentAttribute, fileManager: fileManager) {
            return path
        }
        if let windowTitle {
            for candidate in pathCandidates(in: windowTitle) {
                if let path = resolveExistingDirectory(from: candidate, fileManager: fileManager) {
                    return path
                }
            }
        }
        return nil
    }

    private static func pathCandidates(in title: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:~|/(?:Users|Volumes|private|tmp|var|opt))[^\s|—–•)]*"#) else {
            return []
        }
        let nsTitle = title as NSString
        let matches = regex.matches(in: title, range: NSRange(location: 0, length: nsTitle.length))
        return matches.map { nsTitle.substring(with: $0.range) }
    }

    static func resolveExistingDirectory(
        from rawPathOrURL: String,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = rawPathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expandedPath: String
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            expandedPath = url.path
        } else {
            expandedPath = (trimmed as NSString).expandingTildeInPath
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return expandedPath
        }
        return (expandedPath as NSString).deletingLastPathComponent
    }

    private static func sanitize(_ text: String, limit: Int) -> String {
        let singleLine = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }
}

enum ProcessWorkingDirectoryLookup {
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty"
    ]

    static func isTerminal(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    static func findDirectories(
        forTerminalPID pid: pid_t,
        windowTitle: String?,
        terminalTail: String? = nil,
        limit: Int = 6
    ) -> (primary: String?, all: [String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [(path: String, processName: String?)] = []
        var seenPaths: Set<String> = []

        for childPID in descendantPIDs(of: pid, maxDepth: 5) {
            guard let path = currentWorkingDirectory(of: childPID),
                  path != "/",
                  path != home,
                  !path.hasPrefix(home + "/."),
                  seenPaths.insert(path).inserted else {
                continue
            }
            candidates.append((path: path, processName: processName(of: childPID)))
        }

        let primary = selectBestDirectory(
            candidates: candidates,
            windowTitle: windowTitle,
            terminalTail: terminalTail
        )
        var orderedAll: [String] = []
        if let primary {
            orderedAll.append(primary)
        }
        for candidate in candidates where candidate.path != primary {
            orderedAll.append(candidate.path)
            if orderedAll.count >= limit { break }
        }
        return (primary: primary, all: orderedAll)
    }

    static func selectBestDirectory(
        candidates: [(path: String, processName: String?)],
        windowTitle: String?,
        terminalTail: String?
    ) -> String? {
        guard !candidates.isEmpty else { return nil }

        let searchableHaystacks = [windowTitle, terminalTail]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }

        for haystack in searchableHaystacks {
            let matching = candidates
                .filter { candidate in
                    let name = URL(fileURLWithPath: candidate.path).lastPathComponent.lowercased()
                    return name.count >= 2 && haystack.contains(name)
                }
                .sorted { $0.path.count > $1.path.count }
            if let best = matching.first {
                return best.path
            }
        }

        if let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !title.isEmpty {
            let commandMatches = candidates.filter { candidate in
                guard let name = candidate.processName?.lowercased(), !name.isEmpty else { return false }
                return title == name || title.contains(name)
            }
            if commandMatches.count == 1 {
                return commandMatches[0].path
            }
        }

        if candidates.count == 1 {
            return candidates[0].path
        }
        return nil
    }

    private static func processName(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let endIndex = buffer.firstIndex(of: 0) ?? Int(length)
        return String(decoding: buffer[..<endIndex], as: UTF8.self)
    }

    private static func descendantPIDs(of rootPID: pid_t, maxDepth: Int) -> [pid_t] {
        var result: [pid_t] = []
        var frontier = [rootPID]
        for _ in 0..<maxDepth {
            var nextFrontier: [pid_t] = []
            for parent in frontier {
                let children = directChildPIDs(of: parent)
                result.append(contentsOf: children)
                nextFrontier.append(contentsOf: children)
            }
            if nextFrontier.isEmpty { break }
            frontier = nextFrontier
        }
        return result
    }

    static func directChildPIDs(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while capacity <= 512 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let byteCount = Int32(buffer.count * MemoryLayout<pid_t>.size)
            // Note: proc_listchildpids returns a PID *count*, not a byte count.
            let count = Int(proc_listchildpids(pid, &buffer, byteCount))
            guard count > 0 else { return [] }
            if count < capacity || capacity == 512 {
                return Array(buffer.prefix(min(count, capacity))).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }

    private static func currentWorkingDirectory(of pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, size)
        guard result == size else { return nil }
        return withUnsafePointer(to: &pathInfo.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cString in
                let path = String(cString: cString)
                return path.isEmpty ? nil : path
            }
        }
    }
}

actor GitRepositoryContextCollector {
    private struct CacheEntry {
        let context: GitRepositoryContext?
        let expiresAt: ContinuousClock.Instant
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: Duration = .seconds(30)

    func collect(forDirectory directory: String) async -> GitRepositoryContext? {
        let now = ContinuousClock().now
        if let cached = cache[directory], cached.expiresAt > now {
            return cached.context
        }

        let context = await loadContext(forDirectory: directory)
        cache[directory] = CacheEntry(context: context, expiresAt: now.advanced(by: cacheTTL))
        return context
    }

    private func loadContext(forDirectory directory: String) async -> GitRepositoryContext? {
        if let gitContext = await loadGitContext(forDirectory: directory) {
            return gitContext
        }
        if let svnContext = await loadSVNContext(forDirectory: directory) {
            return svnContext
        }
        return loadPlainWorkspaceContext(forDirectory: directory)
    }

    private func loadGitContext(forDirectory directory: String) async -> GitRepositoryContext? {
        guard let root = await runProcess("/usr/bin/git", arguments: ["rev-parse", "--show-toplevel"], in: directory, timeoutMilliseconds: 400)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty else {
            return nil
        }

        let repoName = URL(fileURLWithPath: root).lastPathComponent
        let branch = await runProcess("/usr/bin/git", arguments: ["rev-parse", "--abbrev-ref", "HEAD"], in: root, timeoutMilliseconds: 400)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let recentCommits = await runProcess("/usr/bin/git", arguments: ["log", "-n", "10", "--pretty=format:%s"], in: root, timeoutMilliseconds: 400)?
            .components(separatedBy: .newlines) ?? []

        var issueSources: [String] = []
        if let branch { issueSources.append(branch) }
        issueSources.append(contentsOf: recentCommits)
        issueSources.append(contentsOf: readProjectDocSnippets(in: root))
        let issueKeys = DictationContextComposer.extractIssueKeys(from: issueSources, limit: 5)

        var fileNames: [String] = []
        var seenFiles: Set<String> = []

        if let statusOutput = await runProcess("/usr/bin/git", arguments: ["status", "--porcelain"], in: root, timeoutMilliseconds: 500) {
            for line in statusOutput.components(separatedBy: .newlines) where line.count > 3 {
                let pathPart = String(line.dropFirst(3))
                    .components(separatedBy: " -> ")
                    .last ?? ""
                let base = URL(fileURLWithPath: pathPart.trimmingCharacters(in: .whitespaces)).lastPathComponent
                if !base.isEmpty, seenFiles.insert(base).inserted {
                    fileNames.append(base)
                }
            }
        }

        if fileNames.count < 8,
           let recentDiff = await runProcess("/usr/bin/git", arguments: ["diff", "--name-only", "HEAD~3..HEAD"], in: root, timeoutMilliseconds: 400) {
            for line in recentDiff.components(separatedBy: .newlines) {
                let base = URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces)).lastPathComponent
                if !base.isEmpty, seenFiles.insert(base).inserted {
                    fileNames.append(base)
                }
            }
        }

        return GitRepositoryContext(
            repositoryName: repoName,
            branchName: branch,
            issueKeys: issueKeys,
            activeFileNames: Array(fileNames.prefix(10))
        )
    }

    private func loadSVNContext(forDirectory directory: String) async -> GitRepositoryContext? {
        guard let root = findAncestorDirectory(containing: ".svn", startingAt: directory) else {
            return nil
        }

        let repoName = URL(fileURLWithPath: root).lastPathComponent
        let issueSources = readProjectDocSnippets(in: root)
        var fileNames: [String] = []
        var seenFiles: Set<String> = []

        if let svnPath = findSVNExecutable(),
           let statusOutput = await runProcess(svnPath, arguments: ["status", "-q"], in: root, timeoutMilliseconds: 800) {
            for line in statusOutput.components(separatedBy: .newlines) where line.count > 8 {
                let pathPart = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                let base = URL(fileURLWithPath: pathPart).lastPathComponent
                if !base.isEmpty, seenFiles.insert(base).inserted {
                    fileNames.append(base)
                }
            }
        }

        let issueKeys = DictationContextComposer.extractIssueKeys(from: issueSources, limit: 5)
        return GitRepositoryContext(
            repositoryName: repoName,
            branchName: nil,
            issueKeys: issueKeys,
            activeFileNames: Array(fileNames.prefix(10))
        )
    }

    private func loadPlainWorkspaceContext(forDirectory directory: String) -> GitRepositoryContext? {
        let snippets = readProjectDocSnippets(in: directory)
        let issueKeys = DictationContextComposer.extractIssueKeys(from: snippets, limit: 5)
        guard !issueKeys.isEmpty else { return nil }
        let repoName = URL(fileURLWithPath: directory).lastPathComponent
        return GitRepositoryContext(
            repositoryName: repoName,
            branchName: nil,
            issueKeys: issueKeys,
            activeFileNames: []
        )
    }

    private func findAncestorDirectory(containing marker: String, startingAt directory: String) -> String? {
        var current = URL(fileURLWithPath: directory).standardizedFileURL
        let fileManager = FileManager.default
        for _ in 0..<8 {
            let candidate = current.appendingPathComponent(marker).path
            if fileManager.fileExists(atPath: candidate) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private func readProjectDocSnippets(in root: String) -> [String] {
        let docNames = ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "README.md"]
        let rootURL = URL(fileURLWithPath: root)
        var snippets: [String] = []
        for name in docNames {
            let fileURL = rootURL.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 16_384),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else {
                continue
            }
            snippets.append(text)
        }
        return snippets
    }

    private func findSVNExecutable() -> String? {
        let candidates = ["/opt/homebrew/bin/svn", "/usr/local/bin/svn", "/usr/bin/svn"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runProcess(
        _ executablePath: String,
        arguments: [String],
        in directory: String,
        timeoutMilliseconds: Int = 500
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                let state = ProcessCaptureState()
                let readHandle = stdout.fileHandleForReading
                readHandle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        state.append(chunk)
                    }
                }

                let timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        state.markTimedOut()
                        process.terminate()
                    }
                }

                process.terminationHandler = { finishedProcess in
                    timeoutWorkItem.cancel()
                    readHandle.readabilityHandler = nil
                    let remaining = readHandle.readDataToEndOfFile()
                    if !remaining.isEmpty {
                        state.append(remaining)
                    }
                    let output: String?
                    if !state.didTimeOut, finishedProcess.terminationStatus == 0 {
                        output = String(data: state.snapshotData(), encoding: .utf8)
                    } else {
                        output = nil
                    }
                    if state.claimResume() {
                        continuation.resume(returning: output)
                    }
                }

                do {
                    try process.run()
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + .milliseconds(timeoutMilliseconds),
                        execute: timeoutWorkItem
                    )
                } catch {
                    timeoutWorkItem.cancel()
                    readHandle.readabilityHandler = nil
                    if state.claimResume() {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

private final class ProcessCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var timedOut = false
    private var resumed = false

    func append(_ chunk: Data) {
        lock.withLock {
            // Cap captured stdout at 256 KB to keep memory bounded on huge trees.
            if data.count < 262_144 {
                data.append(chunk)
            }
        }
    }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }

    func snapshotData() -> Data {
        lock.withLock { data }
    }

    func claimResume() -> Bool {
        lock.withLock {
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }
}

@MainActor
final class DefaultDictationContextProvider: DictationContextProviding {
    private let gitCollector = GitRepositoryContextCollector()

    func captureImmediateContext(
        for target: TargetApplication,
        recentTranscription: String?
    ) -> DictationContextSnapshot {
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.15)

        var windowTitle: String?
        var documentAttribute: String?
        if let focusedWindow = copyElementAttribute(kAXFocusedWindowAttribute, of: appElement) {
            windowTitle = copyStringAttribute(kAXTitleAttribute, of: focusedWindow)
            documentAttribute = copyStringAttribute(kAXDocumentAttribute, of: focusedWindow)
        }

        let isTerminal = ProcessWorkingDirectoryLookup.isTerminal(bundleIdentifier: target.bundleIdentifier)
        var precedingText: String?
        var terminalTail: String?
        if let focusedElement = copyElementAttribute(kAXFocusedUIElementAttribute, of: appElement),
           !isSecureElement(focusedElement),
           let value = copyStringAttribute(kAXValueAttribute, of: focusedElement) {
            if isTerminal {
                // Capture only the tail of the terminal screen using O(1) NSString length
                // for local directory matching and Jira/issue key extraction (never sent verbatim).
                let nsValue = value as NSString
                let tailLength = 2_000
                terminalTail = nsValue.length > tailLength
                    ? nsValue.substring(from: nsValue.length - tailLength)
                    : value
            } else if let range = copySelectedRange(of: focusedElement) {
                precedingText = DictationContextComposer.extractPrecedingText(
                    value: value,
                    selectedLocation: range.location
                )
            }
        }

        let documentPath = DictationContextComposer.extractDirectoryPath(
            documentAttribute: documentAttribute,
            windowTitle: windowTitle
        ) ?? DictationContextComposer.extractDirectoryPath(
            documentAttribute: nil,
            windowTitle: terminalTail
        )

        return DictationContextSnapshot(
            appName: target.name,
            bundleIdentifier: target.bundleIdentifier,
            windowTitle: windowTitle,
            documentPath: documentPath,
            precedingText: precedingText,
            terminalTail: terminalTail,
            recentTranscription: recentTranscription,
            gitContext: nil
        )
    }

    func enrichContext(
        _ snapshot: DictationContextSnapshot,
        target: TargetApplication
    ) async -> DictationContextSnapshot {
        var primaryDirectory = snapshot.documentPath
        var allDirectories: [String] = []
        if let primaryDirectory {
            allDirectories.append(primaryDirectory)
        }

        if ProcessWorkingDirectoryLookup.isTerminal(bundleIdentifier: target.bundleIdentifier) {
            let pid = target.processIdentifier
            let title = snapshot.windowTitle
            let tail = snapshot.terminalTail
            let lookup = await Task.detached(priority: .utility) {
                ProcessWorkingDirectoryLookup.findDirectories(
                    forTerminalPID: pid,
                    windowTitle: title,
                    terminalTail: tail
                )
            }.value
            if primaryDirectory == nil {
                primaryDirectory = lookup.primary
            }
            for dir in lookup.all where !allDirectories.contains(dir) {
                allDirectories.append(dir)
            }
        }

        guard !allDirectories.isEmpty else { return snapshot }

        var primaryContext: GitRepositoryContext?
        var combinedIssueKeys: [String] = []
        var seenKeys: Set<String> = []

        for dir in allDirectories {
            guard let repoContext = await gitCollector.collect(forDirectory: dir) else { continue }
            if dir == primaryDirectory {
                primaryContext = repoContext
            }
            for key in repoContext.issueKeys where seenKeys.insert(key).inserted {
                combinedIssueKeys.append(key)
            }
        }

        var enriched = snapshot
        if let primary = primaryContext {
            enriched.gitContext = GitRepositoryContext(
                repositoryName: primary.repositoryName,
                branchName: primary.branchName,
                issueKeys: combinedIssueKeys,
                activeFileNames: primary.activeFileNames
            )
        } else if !combinedIssueKeys.isEmpty {
            let fallbackName = primaryDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            enriched.gitContext = GitRepositoryContext(
                repositoryName: fallbackName,
                branchName: nil,
                issueKeys: combinedIssueKeys,
                activeFileNames: []
            )
        }
        return enriched
    }

    private func isSecureElement(_ element: AXUIElement) -> Bool {
        if let subrole = copyStringAttribute(kAXSubroleAttribute, of: element),
           subrole == kAXSecureTextFieldSubrole {
            return true
        }
        if let role = copyStringAttribute(kAXRoleAttribute, of: element),
           role == "AXSecureTextField" {
            return true
        }
        return false
    }

    private func copyElementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyStringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: CFString.self) as String
    }

    private func copySelectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }
}
