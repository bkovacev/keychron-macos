import Foundation

/// Ensures only one agent runs at a time.
///
/// The LaunchAgent has KeepAlive set, and the app can also be opened by hand.
/// Two copies each register their own accessory power source, so the keyboard
/// shows up twice in Control Center. An advisory lock on a file in the support
/// directory is enough: the kernel drops it when the process exits, however it
/// exits, so there is no stale-lock case to clean up.
enum SingleInstance {
    private static var handle: FileHandle?

    /// Returns false when another instance already holds the lock.
    static func acquire() -> Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("K10ProBattery", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = directory.appendingPathComponent("agent.lock").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let file = FileHandle(forWritingAtPath: path) else { return true }

        if flock(file.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            try? file.close()
            return false
        }

        handle = file   // held for the process lifetime
        return true
    }
}
