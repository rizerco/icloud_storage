#if os(iOS)
    import Flutter
#elseif os(macOS)
    import FlutterMacOS
#endif

public class ICloudStoragePlugin: NSObject, FlutterPlugin {
    var listStreamHandler: StreamHandler?
    var messenger: FlutterBinaryMessenger?
    var streamHandlers: [String: StreamHandler] = [:]
    let querySearchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]

    public static func register(with registrar: FlutterPluginRegistrar) {
        // Workaround for https://github.com/flutter/flutter/issues/118103.
        #if os(iOS)
            let messenger = registrar.messenger()
        #else
            let messenger = registrar.messenger
        #endif
        let channel = FlutterMethodChannel(name: "icloud_storage", binaryMessenger: messenger)
        let instance = ICloudStoragePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        instance.messenger = messenger
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "gather":
            self.gather(call, result)
        case "upload":
            self.upload(call, result)
        case "download":
            self.download(call, result)
        case "downloadInPlace":
            self.downloadInPlace(call, result)
        case "delete":
            self.delete(call, result)
        case "move":
            self.move(call, result)
        case "createEventChannel":
            self.createEventChannel(call, result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func gather(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let containerId = args["containerId"] as? String,
              let eventChannelName = args["eventChannelName"] as? String
        else {
            result(self.argumentError)
            return
        }

        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
        else {
            result(self.containerError)
            return
        }
        DebugHelper.log("containerURL: \(containerURL.path)")

        let query = NSMetadataQuery()
        query.operationQueue = .main
        query.searchScopes = self.querySearchScopes
        query.predicate = NSPredicate(format: "%K beginswith %@", NSMetadataItemPathKey, containerURL.path)
        self.addGatherFilesObservers(query: query, containerURL: containerURL, eventChannelName: eventChannelName, result: result)

        if !eventChannelName.isEmpty {
            let streamHandler = self.streamHandlers[eventChannelName]!
            streamHandler.onCancelHandler = { [self] in
                self.removeObservers(query)
                query.stop()
                self.removeStreamHandler(eventChannelName)
            }
        }
        query.start()
    }

    private func addGatherFilesObservers(query: NSMetadataQuery, containerURL: URL, eventChannelName: String, result: @escaping FlutterResult) {
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query, queue: query.operationQueue) {
            [self] notification in
            let files = self.mapFileAttributesFromQuery(query: query, containerURL: containerURL)
            self.removeObservers(query)
            if eventChannelName.isEmpty { query.stop() }
            result(files)
        }

        if !eventChannelName.isEmpty {
            NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: query, queue: query.operationQueue) {
                [self] notification in
                let files = self.mapFileAttributesFromQuery(query: query, containerURL: containerURL)
                let streamHandler = self.streamHandlers[eventChannelName]!
                streamHandler.setEvent(files)
            }
        }
    }

    private func mapFileAttributesFromQuery(query: NSMetadataQuery, containerURL: URL) -> [[String: Any?]] {
        var fileMaps: [[String: Any?]] = []
        for item in query.results {
            guard let fileItem = item as? NSMetadataItem else { continue }
            guard let fileURL = fileItem.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }

            let isHidden = (try? fileURL.resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? false
            guard !isHidden else { continue }

            let map: [String: Any?] = [
                "relativePath": String(fileURL.absoluteString.dropFirst(containerURL.absoluteString.count)),
                "absolutePath": fileURL.path,
                "isDirectory": fileURL.isDirectory,
                "displayName": fileItem.value(forAttribute: NSMetadataItemDisplayNameKey),
                "fileSystemName": fileItem.value(forAttribute: NSMetadataItemFSNameKey),
                "sizeInBytes": fileItem.value(forAttribute: NSMetadataItemFSSizeKey),
                "creationDate": (fileItem.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date)?.timeIntervalSince1970,
                "contentChangeDate": (fileItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)?.timeIntervalSince1970,
                "hasUnresolvedConflicts": fileItem.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey),
                "downloadStatus": fileItem.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey),
                "isDownloading": fileItem.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey),
                "isUploaded": fileItem.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey),
                "isUploading": fileItem.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey),
            ]
            fileMaps.append(map)
        }
        return fileMaps
    }

    private func upload(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let containerId = args["containerId"] as? String,
              let localFilePath = args["localFilePath"] as? String,
              let cloudFileName = args["cloudFileName"] as? String,
              let eventChannelName = args["eventChannelName"] as? String
        else {
            result(self.argumentError)
            return
        }

        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
        else {
            result(self.containerError)
            return
        }
        DebugHelper.log("containerURL: \(containerURL.path)")

        let cloudFileURL = containerURL.appendingPathComponent(cloudFileName)
        let localFileURL = URL(fileURLWithPath: localFilePath)

        do {
            if FileManager.default.fileExists(atPath: cloudFileURL.path) {
                try FileManager.default.removeItem(at: cloudFileURL)
            } else {
                let cloudFileDirURL = cloudFileURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: cloudFileDirURL.path) {
                    try FileManager.default.createDirectory(at: cloudFileDirURL, withIntermediateDirectories: true, attributes: nil)
                }
            }
            try FileManager.default.copyItem(at: localFileURL, to: cloudFileURL)
        } catch {
            result(self.nativeCodeError(error))
        }

        if !eventChannelName.isEmpty {
            let query = NSMetadataQuery()
            query.operationQueue = .main
            query.searchScopes = self.querySearchScopes
            query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, cloudFileURL.path)

            let uploadStreamHandler = self.streamHandlers[eventChannelName]!
            uploadStreamHandler.onCancelHandler = { [self] in
                self.removeObservers(query)
                query.stop()
                self.removeStreamHandler(eventChannelName)
            }
            self.addUploadObservers(query: query, eventChannelName: eventChannelName)

            query.start()
        }

        result(nil)
    }

    private func addUploadObservers(query: NSMetadataQuery, eventChannelName: String) {
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query, queue: query.operationQueue) { [self] notification in
            self.onUploadQueryNotification(query: query, eventChannelName: eventChannelName)
        }

        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: query, queue: query.operationQueue) { [self] notification in
            self.onUploadQueryNotification(query: query, eventChannelName: eventChannelName)
        }
    }

    private func onUploadQueryNotification(query: NSMetadataQuery, eventChannelName: String) {
        if query.results.count == 0 {
            return
        }

        guard let fileItem = query.results.first as? NSMetadataItem else { return }
        guard let fileURL = fileItem.value(forAttribute: NSMetadataItemURLKey) as? URL else { return }
        guard let fileURLValues = try? fileURL.resourceValues(forKeys: [.ubiquitousItemUploadingErrorKey]) else { return }
        guard let streamHandler = self.streamHandlers[eventChannelName] else { return }

        if let error = fileURLValues.ubiquitousItemUploadingError {
            streamHandler.setEvent(self.nativeCodeError(error))
            return
        }

        if let progress = fileItem.value(forAttribute: NSMetadataUbiquitousItemPercentUploadedKey) as? Double {
            streamHandler.setEvent(progress)
            if progress >= 100 {
                streamHandler.setEvent(FlutterEndOfEventStream)
                self.removeStreamHandler(eventChannelName)
            }
        }
    }

    private func download(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let containerId = args["containerId"] as? String,
              let cloudFileName = args["cloudFileName"] as? String,
              let localFilePath = args["localFilePath"] as? String,
              let eventChannelName = args["eventChannelName"] as? String
        else {
            result(self.argumentError)
            return
        }

        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
        else {
            result(self.containerError)
            return
        }
        DebugHelper.log("containerURL: \(containerURL.path)")

        let cloudFileURL = containerURL.appendingPathComponent(cloudFileName)
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: cloudFileURL)
        } catch {
            result(self.nativeCodeError(error))
        }

        let query = NSMetadataQuery()
        query.operationQueue = .main
        query.searchScopes = self.querySearchScopes
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, cloudFileURL.path)

        let downloadStreamHandler = self.streamHandlers[eventChannelName]
        downloadStreamHandler?.onCancelHandler = { [self] in
            self.removeObservers(query)
            query.stop()
            self.removeStreamHandler(eventChannelName)
        }

        let localFileURL = URL(fileURLWithPath: localFilePath)
        self.addDownloadObservers(query: query, cloudFileURL: cloudFileURL, localFileURL: localFileURL, eventChannelName: eventChannelName)

        query.start()
        result(nil)
    }

    /// Downloads the file from iCloud Drive but doesn’t move it.
    private func downloadInPlace(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let containerID = arguments["containerId"] as? String,
              let fileName = arguments["fileName"] as? String,
              let eventChannelName = arguments["eventChannelName"] as? String
        else {
            result(self.argumentError)
            return
        }

        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerID)
        else {
            result(self.containerError)
            return
        }
        DebugHelper.log("containerURL: \(containerURL.path)")

        let cloudFileURL = containerURL.appendingPathComponent(fileName)
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: cloudFileURL)
        } catch {
            result(self.nativeCodeError(error))
        }

        let query = NSMetadataQuery()
        query.operationQueue = .main
        query.searchScopes = self.querySearchScopes
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, cloudFileURL.path)

        let downloadStreamHandler = self.streamHandlers[eventChannelName]
        downloadStreamHandler?.onCancelHandler = { [self] in
            self.removeObservers(query)
            query.stop()
            self.removeStreamHandler(eventChannelName)
        }

        self.addDownloadObservers(query: query, cloudFileURL: cloudFileURL, eventChannelName: eventChannelName)

        query.start()
        result(nil)
    }

    private func addDownloadObservers(query: NSMetadataQuery, cloudFileURL: URL, localFileURL: URL? = nil, eventChannelName: String) {
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query, queue: query.operationQueue) { [self] notification in
            self.onDownloadQueryNotification(query: query, cloudFileURL: cloudFileURL, localFileURL: localFileURL, eventChannelName: eventChannelName)
        }

        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSMetadataQueryDidUpdate, object: query, queue: query.operationQueue) { [self] notification in
            self.onDownloadQueryNotification(query: query, cloudFileURL: cloudFileURL, localFileURL: localFileURL, eventChannelName: eventChannelName)
        }
    }

    private func onDownloadQueryNotification(query: NSMetadataQuery, cloudFileURL: URL, localFileURL: URL? = nil, eventChannelName: String) {
        if query.results.count == 0 {
            return
        }

        guard let fileItem = query.results.first as? NSMetadataItem else { return }
        guard let fileURL = fileItem.value(forAttribute: NSMetadataItemURLKey) as? URL else { return }
        guard let fileURLValues = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey, .ubiquitousItemDownloadingStatusKey]) else { return }
        let streamHandler = self.streamHandlers[eventChannelName]

        if let error = fileURLValues.ubiquitousItemDownloadingError {
            streamHandler?.setEvent(self.nativeCodeError(error))
            return
        }

        if let progress = fileItem.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double {
            streamHandler?.setEvent(progress)
        }

        if fileURLValues.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current {
            do {
                if let local = localFileURL {
                    try self.moveCloudFile(at: cloudFileURL, to: local)
                }
                streamHandler?.setEvent(FlutterEndOfEventStream)
                self.removeStreamHandler(eventChannelName)
            } catch {
                streamHandler?.setEvent(self.nativeCodeError(error))
            }
        }
    }

    private func moveCloudFile(at: URL, to: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: to.path) {
                try FileManager.default.removeItem(at: to)
            }
            try FileManager.default.copyItem(at: at, to: to)
        } catch {
            throw error
        }
    }

    private func delete(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let containerId = args["containerId"] as? String,
              let paths = args["paths"] as? [String]
        else {
            result(self.argumentError)
            return
        }

        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
        else {
            result(self.containerError)
            return
        }
        DebugHelper.log("containerURL: \(containerURL.path)")

        for path in paths {
            let fileURL = containerURL.appendingPathComponent(path)
            let fileCoordinator = NSFileCoordinator(filePresenter: nil)
            fileCoordinator.coordinate(writingItemAt: fileURL, options: NSFileCoordinator.WritingOptions.forDeleting, error: nil) {
                writingURL in
                do {
                    var isDir: ObjCBool = false
                    if !FileManager.default.fileExists(atPath: writingURL.path, isDirectory: &isDir) {
                        result(self.fileNotFoundError)
                        return
                    }
                    try FileManager.default.removeItem(at: writingURL)
                    result(nil)
                } catch {
                    DebugHelper.log("error: \(error.localizedDescription)")
                    result(self.nativeCodeError(error))
                }
            }
        }
    }

    private func move(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let containerId = args["containerId"] as? String,
              let atRelativePath = args["atRelativePath"] as? String,
              let toRelativePath = args["toRelativePath"] as? String
        else {
            result(self.argumentError)
            return
        }

        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId)
        else {
            result(self.containerError)
            return
        }
        DebugHelper.log("containerURL: \(containerURL.path)")

        let atURL = containerURL.appendingPathComponent(atRelativePath)
        let toURL = containerURL.appendingPathComponent(toRelativePath)
        let fileCoordinator = NSFileCoordinator(filePresenter: nil)
        fileCoordinator.coordinate(writingItemAt: atURL, options: NSFileCoordinator.WritingOptions.forMoving, writingItemAt: toURL, options: NSFileCoordinator.WritingOptions.forReplacing, error: nil) {
            atWritingURL, toWritingURL in
            do {
                let toDirURL = toWritingURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: toDirURL.path) {
                    try FileManager.default.createDirectory(at: toDirURL, withIntermediateDirectories: true, attributes: nil)
                }
                try FileManager.default.moveItem(at: atWritingURL, to: toWritingURL)
                result(nil)
            } catch {
                DebugHelper.log("error: \(error.localizedDescription)")
                result(self.nativeCodeError(error))
            }
        }
    }

    private func removeObservers(_ query: NSMetadataQuery) {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.NSMetadataQueryDidUpdate, object: query)
    }

    private func createEventChannel(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let eventChannelName = args["eventChannelName"] as? String
        else {
            result(self.argumentError)
            return
        }

        let streamHandler = StreamHandler()
        let eventChannel = FlutterEventChannel(name: eventChannelName, binaryMessenger: self.messenger!)
        eventChannel.setStreamHandler(streamHandler)
        self.streamHandlers[eventChannelName] = streamHandler

        result(nil)
    }

    private func removeStreamHandler(_ eventChannelName: String) {
        self.streamHandlers[eventChannelName] = nil
    }

    let argumentError = FlutterError(code: "E_ARG", message: "Invalid Arguments", details: nil)
    let containerError = FlutterError(code: "E_CTR", message: "Invalid containerId, or user is not signed in, or user disabled iCloud permission", details: nil)
    let fileNotFoundError = FlutterError(code: "E_FNF", message: "The file does not exist", details: nil)

    private func nativeCodeError(_ error: Error) -> FlutterError {
        return FlutterError(code: "E_NAT", message: "Native Code Error", details: "\(error)")
    }
}

class StreamHandler: NSObject, FlutterStreamHandler {
    private var _eventSink: FlutterEventSink?
    var onCancelHandler: (() -> Void)?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self._eventSink = events
        DebugHelper.log("on listen")
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.onCancelHandler?()
        self._eventSink = nil
        DebugHelper.log("on cancel")
        return nil
    }

    func setEvent(_ data: Any) {
        self._eventSink?(data)
    }
}

enum DebugHelper {
    public static func log(_ message: String) {
        #if DEBUG
            print(message)
        #endif
    }
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
