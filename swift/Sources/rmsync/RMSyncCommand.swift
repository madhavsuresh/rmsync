import ArgumentParser
import Foundation

@main
struct RMSyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rmsync",
        abstract: "Bidirectional reMarkable ↔ Markdown sync.",
        subcommands: [
            Daemon.self,
            Status.self,
            StartCmd.self,
            StopCmd.self,
            RestartCmd.self,
            Pause.self,
            Resume.self,
            SyncNow.self,
            Logs.self,
            Conflicts.self,
            Doctor.self,
            Relocate.self,
            Init.self,
            Uninstall.self,
        ],
        defaultSubcommand: nil
    )
}
