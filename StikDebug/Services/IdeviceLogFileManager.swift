//
//  IdeviceLogFileManager.swift
//  StikDebug
//

import Foundation

final class IdeviceLogFileManager {
    static let shared = IdeviceLogFileManager()
    static let logURL = URL.documentsDirectory.appendingPathComponent("idevice_log.txt")

    private static let maximumSize: UInt64 = 20 * 1024 * 1024
    private static let retainedSize: UInt64 = 10 * 1024 * 1024
    private static let checkInterval: TimeInterval = 5

    private let queue = DispatchQueue(label: "com.stik.ideviceLogFile", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {}

    func prepareForLogging() {
        compactIfNeeded()

        queue.async {
            guard self.timer == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
            timer.setEventHandler { [weak self] in
                self?.compactIfNeeded()
            }
            self.timer = timer
            timer.resume()
        }
    }

    private func compactIfNeeded() {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: Self.logURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value > Self.maximumSize,
              let handle = try? FileHandle(forUpdating: Self.logURL) else {
            return
        }

        defer { try? handle.close() }

        do {
            let endOffset = try handle.seekToEnd()
            let startOffset = endOffset > Self.retainedSize ? endOffset - Self.retainedSize : 0
            try handle.seek(toOffset: startOffset)
            var recentData = try handle.readToEnd() ?? Data()

            if startOffset > 0, let newlineIndex = recentData.firstIndex(of: 0x0A) {
                recentData.removeSubrange(recentData.startIndex...newlineIndex)
            }

            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: recentData)
            try handle.synchronize()
        } catch {
            return
        }
    }
}
