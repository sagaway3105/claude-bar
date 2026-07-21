import CoreServices
import Foundation

/// ~/.claude/projects 配下のセッションJSONLへの書き込みをFSEventsで監視し、
/// Claude Codeがトークンを消費中かどうかを検知する。
final class ActivityMonitor {
    private var stream: FSEventStreamRef?
    private let onActivity: () -> Void
    private let watchedPath = NSString(string: "~/.claude/projects").expandingTildeInPath

    init(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
    }

    func start() {
        guard FileManager.default.fileExists(atPath: watchedPath) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let monitor = Unmanaged<ActivityMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            for path in paths where path.hasSuffix(".jsonl") {
                monitor.onActivity()
                break
            }
        }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [watchedPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
