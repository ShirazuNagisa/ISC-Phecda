import Foundation

/// Pinned, reproducible arm64 runtime sources. The archives are downloaded only after
/// SHA-256 verification; PHP and Python use the official source archives because the
/// upstream projects do not publish universal standalone macOS arm64 tarballs.
public enum OfficialRuntimeManifest {
    public static let nodeVersion = "22.14.0"
    public static let goVersion = "1.27.1"
    public static let pythonVersion = "3.13.2"
    public static let phpVersion = "8.4.8"
    public static let javaVersion = "21.0.12+101"

    public static func make() throws -> RuntimeManifest {
        RuntimeManifest(artifacts: [
            try RuntimeArtifact(id: "node-22.14.0-darwin-arm64", runtime: "node", version: nodeVersion, url: URL(string: "https://nodejs.org/dist/v22.14.0/node-v22.14.0-darwin-arm64.tar.gz")!, sha256: "e9404633bc02a5162c5c573b1e2490f5fb44648345d64a958b17e325729a5e42", size: nil, archiveName: "node-v22.14.0-darwin-arm64.tar.gz"),
            try RuntimeArtifact(id: "go-1.27.1-darwin-arm64", runtime: "go", version: goVersion, url: URL(string: "https://go.dev/dl/go1.27.1.darwin-arm64.tar.gz")!, sha256: "ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12", size: 68100347, archiveName: "go1.27.1.darwin-arm64.tar.gz"),
            try RuntimeArtifact(id: "python-3.13.2-source", runtime: "python", version: pythonVersion, url: URL(string: "https://www.python.org/ftp/python/3.13.2/Python-3.13.2.tgz")!, sha256: "b8d79530e3b7c96a5cb2d40d431ddb512af4a563e863728d8713039aa50203f9", size: 29319380, archiveName: "Python-3.13.2.tgz"),
            try RuntimeArtifact(id: "php-8.4.8-source", runtime: "php", version: phpVersion, url: URL(string: "https://www.php.net/distributions/php-8.4.8.tar.gz")!, sha256: "26d5ae014925b7dee3a61ec02422795f008fbb3a36f9355edaee2d9d78b89b07", size: 21782068, archiveName: "php-8.4.8.tar.gz"),
            try RuntimeArtifact(id: "temurin-21.0.12-macos-aarch64", runtime: "java", version: javaVersion, url: URL(string: "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz")!, sha256: "3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998", size: nil, archiveName: "OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz")
        ])
    }
}
