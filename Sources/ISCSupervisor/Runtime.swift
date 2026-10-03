import Foundation
import CryptoKit

public enum SupervisorTaskPhase: String, Codable, Sendable, Equatable {
    case queued, downloadingRuntime, installingDependencies, building, starting, running, stopping, completed, failed, cancelled
}

public struct SupervisorTaskState: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: String
    public var phase: SupervisorTaskPhase
    public var progress: Double
    public var message: String?
    public var startedAt: Date?
    public var updatedAt: Date
    public var finishedAt: Date?
    public var error: String?

    public init(id: UUID = UUID(), kind: String, phase: SupervisorTaskPhase = .queued, progress: Double = 0, message: String? = nil, startedAt: Date? = nil, updatedAt: Date = Date(), finishedAt: Date? = nil, error: String? = nil) {
        self.id = id; self.kind = kind; self.phase = phase; self.progress = min(max(progress, 0), 1)
        self.message = message; self.startedAt = startedAt; self.updatedAt = updatedAt; self.finishedAt = finishedAt; self.error = error
    }

    public mutating func update(phase: SupervisorTaskPhase, progress: Double? = nil, message: String? = nil, now: Date = Date()) {
        self.phase = phase
        if let progress { self.progress = min(max(progress, 0), 1) }
        self.message = message
        self.updatedAt = now
        if startedAt == nil, phase != .queued { startedAt = now }
        if [.completed, .failed, .cancelled].contains(phase) { finishedAt = now; if phase == .completed { self.progress = 1 } }
    }
}

public struct RuntimeArtifact: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let runtime: String
    public let version: String
    public let url: URL
    public let sha256: String
    public let size: Int64?
    public let archiveName: String

    public init(id: String, runtime: String, version: String, url: URL, sha256: String, size: Int64? = nil, archiveName: String) throws {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else { throw RuntimeDownloadError.invalidChecksum }
        self.id = id; self.runtime = runtime; self.version = version; self.url = url; self.sha256 = sha256.lowercased(); self.size = size; self.archiveName = archiveName
    }
}

public struct RuntimeManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let artifacts: [RuntimeArtifact]
    public init(schemaVersion: Int = 1, artifacts: [RuntimeArtifact]) { self.schemaVersion = schemaVersion; self.artifacts = artifacts }
}

public struct RuntimeCatalog: Sendable {
    public let manifest: RuntimeManifest
    public init(manifest: RuntimeManifest) { self.manifest = manifest }
    public init(json: Data, decoder: JSONDecoder = JSONDecoder()) throws {
        self.manifest = try decoder.decode(RuntimeManifest.self, from: json)
    }
    public func artifact(runtime: String, version: String) -> RuntimeArtifact? {
        manifest.artifacts.first { $0.runtime == runtime && $0.version == version }
    }
    public func preferred(runtime: String, version: String? = nil) -> RuntimeArtifact? {
        let candidates = manifest.artifacts.filter { $0.runtime == runtime && (version == nil || $0.version == version) }
        return candidates.max { Self.versionLess($0.version, $1.version) }
    }
    private static func versionLess(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let right = rhs.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b }
        }
        return lhs < rhs
    }
    public func download(runtime: String, version: String, to destination: URL, using downloader: RuntimeDownloader = RuntimeDownloader()) async throws -> URL {
        guard let artifact = artifact(runtime: runtime, version: version) else { throw RuntimeDownloadError.invalidResponse }
        return try await downloader.download(artifact, to: destination)
    }
}

public enum RuntimeDownloadError: Error, LocalizedError, Sendable, Equatable {
    case invalidChecksum, checksumMismatch(expected: String, actual: String), invalidResponse, cancelled, destinationExists
    case unsupportedArchive, unsafeArchiveEntry(String), invalidInstallPath, archiveExtractionFailed(String)
    public var errorDescription: String? {
        switch self { case .invalidChecksum: "The runtime checksum must be a 64-character SHA-256 value."; case let .checksumMismatch(expected, actual): "SHA-256 mismatch (expected \(expected), got \(actual))."; case .invalidResponse: "The runtime download returned an invalid response."; case .cancelled: "The runtime download was cancelled."; case .destinationExists: "The runtime destination already exists."; case .unsupportedArchive: "Only tar.gz and zip runtime archives are supported."; case let .unsafeArchiveEntry(path): "The runtime archive contains an unsafe entry: \(path)."; case .invalidInstallPath: "Runtime and version must be safe path components."; case let .archiveExtractionFailed(message): "Runtime archive extraction failed: \(message)" }
    }
}

public protocol RuntimeDataLoader: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionRuntimeDataLoader: RuntimeDataLoader {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await session.data(for: request) }
}

public struct RuntimeDownloader: Sendable {
    public let loader: any RuntimeDataLoader
    public init(loader: any RuntimeDataLoader = URLSessionRuntimeDataLoader()) { self.loader = loader }

    public func download(_ artifact: RuntimeArtifact, to destination: URL, fileManager: FileManager = .default) async throws -> URL {
        try Task.checkCancellation()
        let request = URLRequest(url: artifact.url, cachePolicy: .reloadIgnoringLocalCacheData)
        let (data, response) = try await loader.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw RuntimeDownloadError.invalidResponse }
        let digest = SHA256.hex(of: data)
        guard digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame else { throw RuntimeDownloadError.checksumMismatch(expected: artifact.sha256, actual: digest) }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).download")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) { throw RuntimeDownloadError.destinationExists }
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }
}


public struct RuntimeInstaller: Sendable {
    public init() {}

    public func install(_ artifact: RuntimeArtifact, archive: URL, to root: URL, fileManager: FileManager = .default) throws -> URL {
        try Task.checkCancellation()
        guard Self.safeComponent(artifact.runtime), Self.safeComponent(artifact.version) else { throw RuntimeDownloadError.invalidInstallPath }
        let ext = artifact.archiveName.lowercased()
        let isZip = ext.hasSuffix(".zip")
        let isTarGz = ext.hasSuffix(".tar.gz")
        guard isZip || isTarGz else { throw RuntimeDownloadError.unsupportedArchive }
        let destination = root.appendingPathComponent(artifact.runtime, isDirectory: true).appendingPathComponent(artifact.version, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) { throw RuntimeDownloadError.destinationExists }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(artifact.version).\(UUID().uuidString).staging", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        try Task.checkCancellation()

        if isZip {
            let listing = try Self.run("/usr/bin/unzip", ["-Z1", archive.path])
            try Self.validateListedPaths(listing)
            let details = try Self.run("/usr/bin/unzip", ["-Z", "-v", archive.path])
            if details.contains("120777") { throw RuntimeDownloadError.unsafeArchiveEntry("ZIP symbolic link") }
            try Task.checkCancellation()
            _ = try Self.run("/usr/bin/unzip", ["-qq", archive.path, "-d", staging.path])
        } else {
            let paths = try Self.run("/usr/bin/tar", ["-tzf", archive.path])
            try Self.validateListedPaths(paths)
            let listing = try Self.run("/usr/bin/tar", ["-tvzf", archive.path])
            for line in listing.split(separator: "\n") {
                guard let first = line.first, first != "l", first != "h" else { throw RuntimeDownloadError.unsafeArchiveEntry(String(line)) }
            }
            try Task.checkCancellation()
            _ = try Self.run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path, "--no-same-owner", "--no-same-permissions"])
        }
        try Task.checkCancellation()
        try Self.validateTree(staging, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) { throw RuntimeDownloadError.destinationExists }
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }

    public func install(runtime: String, version: String, from catalog: RuntimeCatalog, archive: URL, to root: URL, fileManager: FileManager = .default) throws -> URL {
        guard let artifact = catalog.artifact(runtime: runtime, version: version) else { throw RuntimeDownloadError.invalidResponse }
        return try install(artifact, archive: archive, to: root, fileManager: fileManager)
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validatePath(_ path: String) throws {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.hasPrefix("/"), !path.contains("\\"), !normalized.isEmpty,
              normalized.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RuntimeDownloadError.unsafeArchiveEntry(path)
        }
    }

    private static func validateListedPaths(_ output: String) throws {
        for path in output.split(separator: "\n", omittingEmptySubsequences: true) { try validatePath(String(path)) }
    }

    private static func validateTree(_ root: URL, fileManager: FileManager) throws {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], options: []) else {
            throw RuntimeDownloadError.archiveExtractionFailed("Could not inspect extracted files")
        }
        let rootPath = root.standardizedFileURL.path + "/"
        for case let item as URL in enumerator {
            try Task.checkCancellation()
            guard item.standardizedFileURL.path.hasPrefix(rootPath) else { throw RuntimeDownloadError.unsafeArchiveEntry(item.path) }
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw RuntimeDownloadError.unsafeArchiveEntry(item.lastPathComponent)
            }
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw RuntimeDownloadError.archiveExtractionFailed(error.localizedDescription) }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw RuntimeDownloadError.archiveExtractionFailed(String(decoding: errorData, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum SHA256 {
    static func hex(of data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
