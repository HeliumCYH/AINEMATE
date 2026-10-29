import AimateCore
import Foundation

/// Keeps `pet-cli bridge opencode` running under the pet.
///
/// OpenCode's approvals only exist inside its local API, so something has to be
/// polling it while the pet is up. Owning that process here means the bridge's
/// lifetime, its cards and the pet's window all end together — and it starts on
/// its own the next time OpenCode is opened, instead of needing a second command.
final class BridgeSupervisor {
    private var process: Process?
    private var timer: Timer?
    private var stopped = false
    private var nextAttempt = Date.distantPast

    private var cliURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pet-cli")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        // SIGTERM is handled in the bridge, which clears its cards on the way out.
        process?.terminate()
        process = nil
    }

    private func tick() {
        guard !stopped, process == nil, Date() >= nextAttempt else { return }
        // Only spend a process on an agent that is actually running; the bridge
        // would exit at once otherwise and we would be spinning.
        guard let service = OpenCodePermission.service(from: OpenCodePermission.stateFile()),
              OpenCodePermission.isRunning(service),
              let cli = cliURL else { return }
        spawn(cli: cli)
    }

    private func spawn(cli: URL) {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["bridge", "opencode"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // A bridge that dies immediately is a startup problem (another
                // instance holding the lock, usually); retrying every tick
                // would just log noise, so back off for a minute.
                let lived = -started.timeIntervalSinceNow
                self.nextAttempt = lived > 1 ? Date() : Date().addingTimeInterval(60)
                self.process = nil
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            nextAttempt = Date().addingTimeInterval(60)
        }
    }
}
