import Darwin
import Foundation

/// Watches the sessions directory for changes using a `DispatchSource` file
/// system event source. Never polls.
///
/// Two things make this more involved than the textbook example:
///
/// 1. The directory may not exist yet — the app can launch before the hooks are
///    installed. The watcher then waits on the parent and starts as soon as the
///    directory appears, rather than failing permanently.
/// 2. Writes arrive in bursts (several hooks can fire in quick succession), so
///    events are debounced before the store is told to reload.
final class DirectoryWatcher: @unchecked Sendable {
    // @unchecked Sendable: every mutable field below is touched only on `queue`,
    // which is a private serial queue. The invariant is enforced by construction
    // — no member is accessed anywhere else — and `start`/`stop` hop onto it.

    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.sukhman.claudewatch.watcher")

    private var source: (any DispatchSourceFileSystemObject)?
    private var descriptor: CInt = -1
    private var parentSource: (any DispatchSourceFileSystemObject)?
    private var parentDescriptor: CInt = -1
    private var debounceItem: DispatchWorkItem?

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
        parentSource?.cancel()
    }

    func start() {
        queue.async { [self] in
            beginWatching()
        }
    }

    func stop() {
        queue.async { [self] in
            debounceItem?.cancel()
            debounceItem = nil
            source?.cancel(); source = nil
            parentSource?.cancel(); parentSource = nil
        }
    }

    // MARK: - Private, all on `queue`

    private func beginWatching() {
        guard source == nil else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            watchDirectory()
        } else {
            // Not installed yet. Watch the parent and start when it appears.
            watchParentForCreation()
        }
    }

    private func watchDirectory() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Could not open despite existing (permissions, race). Fall back to
            // waiting on the parent rather than giving up forever.
            watchParentForCreation()
            return
        }
        descriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                // The directory itself went away. Tear down and wait for it back.
                self.teardownDirectory()
                self.watchParentForCreation()
                self.scheduleNotify()
                return
            }
            self.scheduleNotify()
        }
        src.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source = src
        src.resume()

        // Something may have changed between the existence check and the open.
        scheduleNotify()
    }

    private func teardownDirectory() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func watchParentForCreation() {
        guard parentSource == nil else { return }
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let fd = open(parent.path, O_EVTONLY)
        guard fd >= 0 else { return }
        parentDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.url.path) {
                self.parentSource?.cancel()
                self.parentSource = nil
                self.parentDescriptor = -1
                self.watchDirectory()
            }
        }
        src.setCancelHandler { [parentDescriptor] in
            if parentDescriptor >= 0 { close(parentDescriptor) }
        }
        parentSource = src
        src.resume()
    }

    /// Coalesce a burst of hook writes into one reload. Several hooks firing in
    /// sequence must not cause a burst of redraws.
    private func scheduleNotify() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + Metrics.debounceInterval, execute: item)
    }
}
