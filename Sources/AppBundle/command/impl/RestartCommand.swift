import AppKit
import Common

/// Set once a restart is scheduled. The process normally exits shortly after; the deadline only keeps a stuck
/// request from blocking all further restarts if termination never got scheduled.
@MainActor private var restartPendingUntil: ContinuousClock.Instant? = nil
@MainActor private var restartIsPending: Bool { restartPendingUntil.map { $0 > .now } ?? false }
@MainActor private var restartTerminationIsScheduled = false

/// The delay starts after the command's refresh session ends, so the socket server gets to answer the CLI first.
@MainActor private let restartTerminationDelay: Duration = .milliseconds(400)
@MainActor private let restartHelperTimeoutTenthsOfSecond = 150

struct RestartCommand: Command {
    let args: RestartCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        if restartIsPending {
            return .fail(io.err("AeroSpace restart is already in progress"))
        }
        guard !serverArgs.isReadOnly else {
            return .fail(io.err("Restart is unavailable in read-only mode"))
        }
        guard let bundle = runningAppBundleUrl() else {
            return .fail(io.err("""
                Restart needs a running AeroSpace.app bundle, but \(Bundle.main.bundleURL.path.singleQuoted) is not one.
                Start AeroSpace from an .app bundle (an installed or local release build) to use restart.
                """))
        }
        do {
            try spawnRestartHelper(bundle: bundle)
        } catch {
            return .fail(io.err("Can't start the restart helper: \(error.localizedDescription). AeroSpace was not restarted"))
        }
        restartPendingUntil = .now + .seconds(10)
        io.out("""
            Restarting \(aeroSpaceAppName). Window layout isn't preserved.
            'command-after-restart' runs once after restart if it is configured.
            """)
        return .succ
    }
}

/// Termination is deferred until the current refresh session finishes, so the CLI response isn't cut off.
@MainActor
func terminateIfRestartIsPending() {
    guard restartIsPending, !restartTerminationIsScheduled else { return }
    restartTerminationIsScheduled = true
    Task.startUnstructured { @MainActor in
        try? await Task.sleep(for: restartTerminationDelay)
        terminationHandler?.beforeTermination()
        terminateApp()
    }
}

/// The running executable must be the bundle's own main executable, so restart can't spawn an unrelated binary.
@MainActor
private func runningAppBundleUrl() -> URL? {
    let bundleUrl = Bundle.main.bundleURL
    guard bundleUrl.pathExtension == "app",
          let executableUrl = Bundle.main.executableURL,
          let bundleExecutable = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String,
          FileManager.default.isExecutableFile(atPath: executableUrl.path),
          executableUrl.resolvingSymlinksInPath().path ==
              bundleUrl.appending(path: "Contents/MacOS/\(bundleExecutable)").resolvingSymlinksInPath().path
    else { return nil }
    return bundleUrl
}

@MainActor
private func spawnRestartHelper(bundle: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    // Arguments are positional parameters, so spaces and quotes in the bundle path stay literal data
    process.arguments = [
        "-c", restartHelperScript,
        "aerospace-restart-helper", // $0
        myPid.description, // $1
        bundle.path, // $2
        restartHelperTimeoutTenthsOfSecond.description, // $3
        serverArgs.configLocation ?? "", // $4
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
}

// The helper outlives the app: it waits for this pid to exit, then relaunches the exact bundle path.
// open -n avoids reusing a dying LaunchServices instance. On timeout nothing is launched; nothing is killed.
private let restartHelperScript = """
    i=0
    while [ "$i" -lt "$3" ] && kill -0 "$1" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$1" 2>/dev/null; then
        exit 1
    fi
    sleep 0.2
    if [ -n "$4" ]; then
        exec /usr/bin/open -n "$2" --args --after-restart --config-path "$4"
    fi
    exec /usr/bin/open -n "$2" --args --after-restart
    """
