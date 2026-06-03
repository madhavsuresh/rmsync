import Foundation
import RMApiMockCore

let result = RMApiMockCommand.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    stdin: FileHandle.standardInput.readDataToEndOfFile(),
    cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    environment: ProcessInfo.processInfo.environment
)

if let data = result.stdout.data(using: .utf8), !data.isEmpty {
    FileHandle.standardOutput.write(data)
}
if let data = result.stderr.data(using: .utf8), !data.isEmpty {
    FileHandle.standardError.write(data)
}

exit(result.exitCode)
