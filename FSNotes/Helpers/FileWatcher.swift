import Cocoa

final class FileWatcher {
    let filePaths: [String]
    var callback: ((FileWatcherEvent) -> Void)?
    var queue: DispatchQueue?
    private var streamRef: FSEventStreamRef?
    private let streams: Streams
    private final class Context {
        weak var watcher: FileWatcher?
        init(_ watcher: FileWatcher) { self.watcher = watcher }
    }
    deinit { stop() }

    // Injectable creation/start boundaries let regression tests exercise actual
    // stream ownership and failure cleanup without exhausting system resources.
    struct Streams {
        var create: (FSEventStreamCallback, UnsafeMutablePointer<FSEventStreamContext>, CFArray) -> FSEventStreamRef?
        var start: (FSEventStreamRef) -> Bool
        static let system = Streams(create: { callback, context, paths in
            FSEventStreamCreate(kCFAllocatorDefault, callback, context, paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0,
                UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        }, start: { FSEventStreamStart($0) })
    }

    init(_ paths: [String], streams: Streams = .system) {
        filePaths = Array(Set(paths.filter { !$0.isEmpty })).sorted()
        self.streams = streams
    }

    @discardableResult
    func start() -> Bool {
        guard streamRef == nil else { return true }
        guard !filePaths.isEmpty else { return false }
        let owner = Context(self)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(owner).toOpaque(),
            retain: Self.retainCallback, release: Self.releaseCallback, copyDescription: nil)
        guard let stream = streams.create(Self.eventCallback, &context, filePaths as CFArray) else { return false }
        if let queue = queue { FSEventStreamSetDispatchQueue(stream, queue) }
        else { FSEventStreamSetDispatchQueue(stream, .main) }
        guard streams.start(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        streamRef = stream
        return true
    }

    func stop() {
        guard let stream = streamRef else { return }
        streamRef = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, count, eventPaths, flags, ids in
        guard let info = info,
              let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String],
              paths.count >= count else { return }
        guard let watcher = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().watcher else { return }
        for index in 0..<count { watcher.callback?(FileWatcherEvent(ids[index], paths[index], flags[index])) }
    }
    private static let retainCallback: CFAllocatorRetainCallBack = { info in
        if let info = info { _ = Unmanaged<Context>.fromOpaque(info).retain() }
        return info
    }
    private static let releaseCallback: CFAllocatorReleaseCallBack = { info in
        if let info = info { Unmanaged<Context>.fromOpaque(info).release() }
    }
}

extension FileWatcher {
    convenience init(_ paths: [String], _ callback: @escaping (FileWatcherEvent) -> Void) {
        self.init(paths)
        self.callback = callback
    }
}
