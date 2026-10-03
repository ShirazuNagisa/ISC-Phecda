import Foundation
import Testing
@testable import ISCSupervisor

struct DockerComposeInspectorTests {
    @Test func fixedCommandSummarizesFixtureWithoutEnvironmentValues() async throws {
        let runner = ComposeFixtureRunner(json: """
        {"services": {
          "web": {
            "ports": [{"target": 80, "published": "8080"}, {"target": 443, "published": 8443}, {"target": 9000}, {"target": 7000, "published": "7000-7005"}],
            "volumes": [{"type": "bind", "source": "/srv/www", "target": "/app", "read_only": true}, {"type": "volume", "source": "data", "target": "/data"}, {"type": "tmpfs", "target": "/tmp"}, "cache:/cache:rw"],
            "environment": {"TOKEN": "secret-token-value", "DEBUG": false, "UNSET": null, "COUNT": 2},
            "labels": {"secret": "secret-label-value"}
          },
          "db": {"environment": ["PASSWORD=secret-password-value", "INHERITED", "PASSWORD=another-secret"]},
          "empty": {}
        }}
        """)
        let summary = try await DockerComposeInspector(runner: runner).inspect(file: "/tmp/compose project/docker-compose.yml")
        #expect(await runner.commands == [["compose", "-f", "/tmp/compose project/docker-compose.yml", "config", "--format", "json"]])
        #expect(summary.services.map(\.name) == ["db", "empty", "web"])
        let web = try #require(summary.services.last)
        #expect(web.ports.map(\.published) == ["8080", "8443", nil, "7000-7005"])
        #expect(web.ports.map(\.target) == [80, 443, 9000, 7000])
        #expect(web.volumes == ["/srv/www:/app:ro", "data:/data", "/tmp", "cache:/cache:rw"])
        #expect(web.environmentVariableNames == ["COUNT", "DEBUG", "TOKEN", "UNSET"])
        #expect(summary.services[0].environmentVariableNames == ["INHERITED", "PASSWORD"])
        #expect(summary.services[1].ports.isEmpty)
        #expect(summary.services[1].volumes.isEmpty)
        #expect(summary.services[1].environmentVariableNames.isEmpty)
        let encoded = try JSONEncoder().encode(summary)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("secret"))
        #expect(try JSONDecoder().decode(DockerComposeSummary.self, from: encoded) == summary)
    }

    @Test(arguments: ["", "compose.yml", "~/compose.yml", "/", "/tmp/", "/tmp/a;whoami", "/tmp/a|id", "/tmp/a&b", "/tmp/$(id)", "/tmp/`id`", "/tmp/a>b", "/tmp/a<b", "/tmp/a\nb", "/tmp/a\rb", "/tmp/a\u{0}b", "/tmp/a'b", "/tmp/a\"b", "/tmp/a\\b", "/tmp/a*b", "/tmp/a?b", "/tmp/[ab]", "/tmp/{ab}", "/tmp/a#b", "/tmp/a!b", "/tmp/a~b"])
    func rejectsUnsafePathsBeforeRunning(file: String) async {
        let runner = ComposeFixtureRunner(json: "{\"services\":{}}")
        await #expect(throws: DockerComposeInspectionError.invalidFilePath) {
            try await DockerComposeInspector(runner: runner).inspect(file: file)
        }
        #expect(await runner.commands.isEmpty)
    }

    @Test(arguments: ["not JSON secret-value", "{}", "{\"services\":[]}", "{\"services\":{\"web\":{\"ports\":[{\"target\":\"secret-value\"}]}}}"])
    func malformedConfigurationHasSanitizedError(json: String) async {
        await #expect(throws: DockerComposeInspectionError.invalidConfiguration) {
            try await DockerComposeInspector(runner: ComposeFixtureRunner(json: json)).inspect(file: "/tmp/compose.yml")
        }
    }

    @Test func propagatesCommandFailureWithoutReturningSummary() async {
        await #expect(throws: DockerComposeInspectionError.commandFailed(17)) {
            try await DockerComposeInspector(runner: ComposeFixtureRunner(json: "{}", failure: .commandFailed(17))).inspect(file: "/tmp/compose.yml")
        }
    }

    @Test func acceptsEmptyServicesAndNullOptionalFields() async throws {
        let empty = try await DockerComposeInspector(runner: ComposeFixtureRunner(json: "{\"services\":{}}")).inspect(file: "/tmp/compose.yml")
        #expect(empty.services.isEmpty)
        let null = try await DockerComposeInspector(runner: ComposeFixtureRunner(json: "{\"services\":{\"web\":{\"ports\":null,\"volumes\":null,\"environment\":null}}}")).inspect(file: "/tmp/compose.yml")
        #expect(null.services == [DockerComposeServiceSummary(name: "web", ports: [], volumes: [], environmentVariableNames: [])])
    }

    @Test func productionRunnerRejectsOtherCommandsWithoutDocker() async {
        await #expect(throws: DockerComposeInspectionError.invalidFilePath) {
            try await DockerComposeProcessRunner().run(arguments: ["compose", "-f", "/tmp/compose.yml", "up", "--format", "json"])
        }
    }
}

private actor ComposeFixtureRunner: DockerComposeCommandRunner {
    let json: String
    let failure: DockerComposeInspectionError?
    private(set) var commands: [[String]] = []
    init(json: String, failure: DockerComposeInspectionError? = nil) { self.json = json; self.failure = failure }

    func run(arguments: [String]) async throws -> Data {
        commands.append(arguments)
        if let failure { throw failure }
        return Data(json.utf8)
    }
}
