import Foundation
import CoreServices

final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    init(url: URL, onChange: @escaping () -> Void) throws {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { throw CocoaError(.fileReadUnknown) }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else { stop(); throw CocoaError(.fileReadUnknown) }
    }
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
    deinit { stop() }
}
