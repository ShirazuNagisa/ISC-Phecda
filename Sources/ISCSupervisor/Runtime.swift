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

public enum RuntimeDownloadError: Error, LocalizedError, Sendable, Equatable {
    case invalidChecksum, checksumMismatch(expected: String, actual: String), invalidResponse, cancelled, destinationExists
    public var errorDescription: String? {
        switch self { case .invalidChecksum: "The runtime checksum must be a 64-character SHA-256 value."; case let .checksumMismatch(expected, actual): "SHA-256 mismatch (expected \(expected), got \(actual))."; case .invalidResponse: "The runtime download returned an invalid response."; case .cancelled: "The runtime download was cancelled."; case .destinationExists: "The runtime destination already exists." }
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

private enum SHA256 {
    static func hex(of data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
