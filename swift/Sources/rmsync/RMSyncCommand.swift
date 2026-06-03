import ArgumentParser
import Foundation

@main
struct RMSyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rmsync",
        abstract: "Explicit reMarkable cloud push/pull for a Markdown tree.",
        discussion: """
        Current sync is explicit:
          rmsync pull
          rmsync diff [path]
          rmsync accept <path>    # or: rmsync accept --all
          rmsync push [path ...]

        The daemon keeps status, menu bar, dashboard, and IPC online. It does not poll the cloud or watch local files for background mutation.
        """,
        // ``--version`` prints Version.current (rewritten to the tag
        // during ``brew install`` — see Formula/rmsync.rb). ``rmsync
        // status`` separately reports the running *daemon's* version
        // over IPC; if those two diverge, the on-disk binary has been
        // upgraded but the daemon hasn't been kicked yet.
        version: Version.current,
        subcommands: [
            Daemon.self,
            Status.self,
            PullCmd.self,
            DiffCmd.self,
            AcceptCmd.self,
            PushCmd.self,
            ForcePushCmd.self,
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
            TrashCmd.self,
            History.self,
            RetryParked.self,
            Errors.self,
        ],
        defaultSubcommand: nil
    )
}
