import Foundation
import ISCSupervisor

@main
struct PhecdaSupervisor {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--state-directory" && !arguments[1].isEmpty) else {
                try emit(SupervisorServiceResponse(error: SupervisorServiceError(code: "invalid_arguments", message: "Usage: PhecdaSupervisor [--state-directory PATH]")))
                return
            }
            let directory = arguments.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PhecdaSupervisor", isDirectory: true)
                : URL(fileURLWithPath: arguments[1], isDirectory: true)
            let service = try SupervisorService(stateDirectory: directory)
            await service.reconcile()
            do {
                while let line = readLine() {
                    let response = await service.handleLine(Data(line.utf8))
                    do {
                        try emit(response)
                    } catch let error as EncodingError {
                        try emit(SupervisorServiceResponse(error: SupervisorServiceError(code: "encoding_failed", message: error.localizedDescription)))
                    }
                }
            } catch {
                await service.shutdown()
                return // A closed output stream cannot receive an error response.
            }
            await service.shutdown()
        } catch {
            try? emit(SupervisorServiceResponse(error: SupervisorServiceError(code: "startup_failed", message: error.localizedDescription)))
        }
    }

    private static func emit(_ response: SupervisorServiceResponse) throws {
        var data = try SupervisorServiceCodec.encodeResponse(response)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
