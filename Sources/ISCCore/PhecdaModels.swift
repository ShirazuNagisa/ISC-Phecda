import Foundation

public enum ServerPurpose: String, Codable, Sendable, CaseIterable {
    case website
    case api
    case gameServer
    case fileService
    case custom
}

public enum DeploymentSource: Codable, Sendable, Equatable {
    case directory(path: String)
    case archive(path: String)
    case git(url: String, ref: String?)
}

public enum DockerSource: Codable, Sendable, Equatable {
    case composeFile(path: String)
    case dockerfileDirectory(path: String)
    case image(reference: String)
    case command(command: String)
}

public enum ProjectSource: Codable, Sendable, Equatable {
    case nonDocker(DeploymentSource)
    case docker(DockerSource)
}

public enum RuntimeKind: String, Codable, Sendable, CaseIterable {
    case staticFiles
    case node
    case python
    case php
    case go
    case java
    case docker
}

public struct StackEvidence: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let file: String
    public let signal: String
    public let confidence: Double
    public init(id: UUID = UUID(), file: String, signal: String, confidence: Double) {
        self.id = id; self.file = file; self.signal = signal; self.confidence = confidence
    }
}

public struct PhecdaProject: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var purpose: ServerPurpose
    public var source: ProjectSource
    public var detectedRuntime: RuntimeKind?
    public var selectedPresetID: String?
    public var workspacePath: String?
    public var deploymentID: UUID?
    public var publicServiceID: UUID?
    public var evidence: [StackEvidence]
    public init(id: UUID = UUID(), name: String, purpose: ServerPurpose, source: ProjectSource, detectedRuntime: RuntimeKind? = nil, selectedPresetID: String? = nil, workspacePath: String? = nil, deploymentID: UUID? = nil, publicServiceID: UUID? = nil, evidence: [StackEvidence] = []) {
        self.id = id; self.name = name; self.purpose = purpose; self.source = source; self.detectedRuntime = detectedRuntime; self.selectedPresetID = selectedPresetID; self.workspacePath = workspacePath; self.deploymentID = deploymentID; self.publicServiceID = publicServiceID; self.evidence = evidence
    }
}

public struct PhecdaPreset: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let version: String
    public let title: String
    public let runtime: RuntimeKind
    public let dockerOnly: Bool
    public let defaultPort: Int
    public let detectorFiles: [String]
    public let runCommand: String
    public init(id: String, version: String, title: String, runtime: RuntimeKind, dockerOnly: Bool = false, defaultPort: Int, detectorFiles: [String], runCommand: String) {
        self.id = id; self.version = version; self.title = title; self.runtime = runtime; self.dockerOnly = dockerOnly; self.defaultPort = defaultPort; self.detectorFiles = detectorFiles; self.runCommand = runCommand
    }
}

public enum DeploymentState: String, Codable, Sendable { case draft, scanning, preparing, building, running, stopped, failed }
public struct PhecdaDeployment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public var presetID: String
    public var state: DeploymentState
    public var localPort: Int?
    public var lastError: String?
    public init(id: UUID = UUID(), projectID: UUID, presetID: String, state: DeploymentState = .draft, localPort: Int? = nil, lastError: String? = nil) {
        self.id = id; self.projectID = projectID; self.presetID = presetID; self.state = state; self.localPort = localPort; self.lastError = lastError
    }
}

public enum PhecdaPresetCatalog {
    public static let nonDocker: [PhecdaPreset] = [
        PhecdaPreset(id: "static-html", version: "1", title: "Static HTML", runtime: .staticFiles, defaultPort: 8080, detectorFiles: ["index.html"], runCommand: "static-server"),
        PhecdaPreset(id: "node-auto", version: "1", title: "Node.js application", runtime: .node, defaultPort: 3000, detectorFiles: ["package.json"], runCommand: "npm start"),
        PhecdaPreset(id: "python-auto", version: "1", title: "Python web application", runtime: .python, defaultPort: 8000, detectorFiles: ["requirements.txt", "pyproject.toml"], runCommand: "auto-detect"),
        PhecdaPreset(id: "php-composer", version: "1", title: "PHP website", runtime: .php, defaultPort: 8080, detectorFiles: ["composer.json", "index.php"], runCommand: "php -S"),
        PhecdaPreset(id: "go-module", version: "1", title: "Go web service", runtime: .go, defaultPort: 8080, detectorFiles: ["go.mod"], runCommand: "built binary"),
        PhecdaPreset(id: "java-build", version: "1", title: "Java web application", runtime: .java, defaultPort: 8080, detectorFiles: ["pom.xml", "build.gradle"], runCommand: "java -jar")
    ]
    public static let docker: [PhecdaPreset] = [
        PhecdaPreset(id: "docker-compose", version: "1", title: "Docker Compose", runtime: .docker, dockerOnly: true, defaultPort: 8080, detectorFiles: ["compose.yaml", "compose.yml", "docker-compose.yml"], runCommand: "docker compose up"),
        PhecdaPreset(id: "dockerfile", version: "1", title: "Dockerfile project", runtime: .docker, dockerOnly: true, defaultPort: 8080, detectorFiles: ["Dockerfile"], runCommand: "docker build && docker run"),
        PhecdaPreset(id: "docker-image", version: "1", title: "Docker image", runtime: .docker, dockerOnly: true, defaultPort: 8080, detectorFiles: [], runCommand: "docker run"),
        PhecdaPreset(id: "docker-command", version: "1", title: "Docker quick command", runtime: .docker, dockerOnly: true, defaultPort: 8080, detectorFiles: [], runCommand: "user-confirmed command")
    ]
}
