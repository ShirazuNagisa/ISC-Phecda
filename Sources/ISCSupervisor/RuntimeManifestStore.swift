import Foundation
import CryptoKit

public enum RuntimeManifestStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidLocation, invalidManifest, insecureURL, checksumMismatch(expected: String, actual: String), unavailable
    public var errorDescription: String? { switch self { case .invalidLocation: "The runtime manifest location is invalid."; case .invalidManifest: "The runtime manifest is invalid."; case .insecureURL: "Runtime manifests must be fetched over HTTPS."; case let .checksumMismatch(expected, actual): "Manifest checksum mismatch (expected \(expected), got \(actual))."; case .unavailable: "The runtime manifest is unavailable." } }
}

public actor RuntimeManifestStore {
    public let location: URL
    private var current: RuntimeManifest?
    public init(location: URL) throws {
        guard location.isFileURL, location.path.hasPrefix("/") else { throw RuntimeManifestStoreError.invalidLocation }
        self.location = location
        if let data = try? Data(contentsOf: location) { current = try Self.decode(data) }
    }
    public func manifest() -> RuntimeManifest? { current }
    public func installOfficialIfMissing() throws {
        guard current == nil else { return }
        try replace(with: OfficialRuntimeManifest.make())
    }

    public func catalog() -> RuntimeCatalog? { current.map(RuntimeCatalog.init(manifest:)) }
    public func replace(with manifest: RuntimeManifest) throws {
        try Self.validate(manifest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = location.deletingLastPathComponent().appendingPathComponent(".\(location.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: location.path) { _ = try FileManager.default.replaceItemAt(location, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: location) }
        current = manifest
    }
    public func refresh(url: URL, expectedSHA256: String, loader: any RuntimeDataLoader = URLSessionRuntimeDataLoader()) async throws {
        guard url.scheme?.lowercased() == "https", expectedSHA256.count == 64, expectedSHA256.allSatisfy({ $0.isHexDigit }) else { throw RuntimeManifestStoreError.insecureURL }
        let (data, response) = try await loader.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw RuntimeManifestStoreError.unavailable }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else { throw RuntimeManifestStoreError.checksumMismatch(expected: expectedSHA256, actual: actual) }
        try replace(with: Self.decode(data))
    }
    private static func decode(_ data: Data) throws -> RuntimeManifest { do { let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data); try validate(manifest); return manifest } catch let error as RuntimeManifestStoreError { throw error } catch { throw RuntimeManifestStoreError.invalidManifest } }
    private static func validate(_ manifest: RuntimeManifest) throws {
        guard manifest.schemaVersion > 0, !manifest.artifacts.isEmpty else { throw RuntimeManifestStoreError.invalidManifest }
        var ids = Set<String>()
        for artifact in manifest.artifacts { guard ids.insert(artifact.id).inserted, artifact.url.scheme?.lowercased() == "https", artifact.archiveName == URL(fileURLWithPath: artifact.archiveName).lastPathComponent, !artifact.archiveName.contains("..") else { throw RuntimeManifestStoreError.invalidManifest } }
    }
}
