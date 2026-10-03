import Foundation

public enum DeploymentLedgerError: Error, LocalizedError, Sendable, Equatable {
    case invalidDirectory(URL)
    case sourceAndReleaseOverlap
    case unknownRelease(UUID)
    case noPreviousRelease(UUID)
    case releaseOutsideRoot(URL)
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidDirectory(url): "Expected a directory at \(url.path)."
        case .sourceAndReleaseOverlap: "The release directory must not be the user source directory."
        case let .unknownRelease(id): "Unknown deployment release: \(id)."
        case let .noPreviousRelease(id): "No previous release exists for deployment \(id)."
        case let .releaseOutsideRoot(url): "The release directory is outside the ledger root: \(url.path)."
        case .persistenceFailed: "The deployment ledger could not be persisted."
        }
    }
}

public struct DeploymentRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let deploymentID: UUID
    public let version: Int
    public let sourceDirectory: URL
    public let releaseDirectory: URL
    public let runCommand: PresetCommand
    public let localPort: Int
    public let createdAt: Date
    public let previousReleaseID: UUID?

    public init(
        id: UUID = UUID(),
        deploymentID: UUID,
        version: Int,
        sourceDirectory: URL,
        releaseDirectory: URL,
        runCommand: PresetCommand,
        localPort: Int,
        createdAt: Date = Date(),
        previousReleaseID: UUID? = nil
    ) {
        self.id = id
        self.deploymentID = deploymentID
        self.version = version
        self.sourceDirectory = sourceDirectory
        self.releaseDirectory = releaseDirectory
        self.runCommand = runCommand
        self.localPort = localPort
        self.createdAt = createdAt
        self.previousReleaseID = previousReleaseID
    }
}

public struct DeploymentLedgerSnapshot: Codable, Sendable, Equatable {
    public let records: [DeploymentRecord]
    public let currentReleaseID: UUID?

    public init(records: [DeploymentRecord] = [], currentReleaseID: UUID? = nil) {
        self.records = records
        self.currentReleaseID = currentReleaseID
    }
}

/// Durable release metadata. It never removes or mutates the source directory.
public actor DeploymentLedger {
    private struct Document: Codable {
        var records: [DeploymentRecord]
        var currentReleaseID: UUID?
    }

    public let root: URL
    private let fileManager: FileManager
    private let ledgerURL: URL
    private let pointerURL: URL
    private var document: Document

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        self.ledgerURL = root.appendingPathComponent("deployment-ledger.json")
        self.pointerURL = root.appendingPathComponent("current-release")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: ledgerURL), !data.isEmpty {
            self.document = try JSONDecoder.deploymentLedger.decode(Document.self, from: data)
        } else {
            self.document = Document(records: [], currentReleaseID: nil)
        }
    }

    public func snapshot() -> DeploymentLedgerSnapshot {
        DeploymentLedgerSnapshot(records: document.records, currentReleaseID: document.currentReleaseID)
    }

    public func currentRelease() -> DeploymentRecord? {
        guard let id = document.currentReleaseID else { return nil }
        return document.records.first { $0.id == id }
    }

    public func record(
        deploymentID: UUID,
        sourceDirectory: URL,
        releaseDirectory: URL,
        runCommand: PresetCommand,
        localPort: Int,
        createdAt: Date = Date()
    ) throws -> DeploymentRecord {
        let source = sourceDirectory.standardizedFileURL
        let release = releaseDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: release.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DeploymentLedgerError.invalidDirectory(release)
        }
        guard source != release else { throw DeploymentLedgerError.sourceAndReleaseOverlap }
        guard release.path == root.path || release.path.hasPrefix(root.path + "/") else {
            throw DeploymentLedgerError.releaseOutsideRoot(release)
        }

        let prior = document.records
            .filter { $0.deploymentID == deploymentID }
            .max { $0.version < $1.version }
        let nextVersion = (prior?.version ?? 0) + 1
        let result = DeploymentRecord(
            deploymentID: deploymentID,
            version: nextVersion,
            sourceDirectory: source,
            releaseDirectory: release,
            runCommand: runCommand,
            localPort: localPort,
            createdAt: createdAt,
            previousReleaseID: prior?.id
        )
        document.records.append(result)
        try persist()
        return result
    }

    public func activate(_ releaseID: UUID) throws -> DeploymentRecord {
        guard let record = document.records.first(where: { $0.id == releaseID }) else {
            throw DeploymentLedgerError.unknownRelease(releaseID)
        }
        try writeAtomically(Data(record.releaseDirectory.path.utf8), to: pointerURL)
        document.currentReleaseID = releaseID
        try persist()
        return record
    }

    public func rollback(deploymentID: UUID) throws -> DeploymentRecord {
        guard let current = currentRelease(), current.deploymentID == deploymentID else {
            throw DeploymentLedgerError.noPreviousRelease(deploymentID)
        }
        guard let previous = document.records
            .filter({ $0.deploymentID == deploymentID && $0.version < current.version })
            .max(by: { $0.version < $1.version }) else {
            throw DeploymentLedgerError.noPreviousRelease(deploymentID)
        }
        return try activate(previous.id)
    }

    private func persist() throws {
        do {
            let data = try JSONEncoder.deploymentLedger.encode(document)
            try writeAtomically(data, to: ledgerURL)
        } catch {
            throw DeploymentLedgerError.persistenceFailed
        }
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? fileManager.removeItem(at: temporary) }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}

private extension JSONEncoder {
    static var deploymentLedger: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var deploymentLedger: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
