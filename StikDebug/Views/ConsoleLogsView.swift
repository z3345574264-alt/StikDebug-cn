//
//  ConsoleLogsView.swift
//  StikDebug
//
//  Created by neoarz on 3/29/25.
//

import SwiftUI
import UIKit

struct ConsoleLogsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var logManager = LogManager.shared
    @StateObject private var systemLogStream = SystemLogStream()
    @State private var selectedConsoleTab: ConsoleTab = .idevice
    @State private var jitScrollView: ScrollViewProxy? = nil
    @State private var showingCustomAlert = false
    @State private var alertMessage = ""
    @State private var alertTitle = ""
    
    @State private var logCheckTimer: Timer? = nil
    
    @State private var isViewActive = false
    @State private var lastProcessedLineCount = 0
    @State private var isLoadingLogs = false
    @State private var jitIsAtBottom = true
    @State private var syslogIsAtBottom = true
    @State private var syslogSearchText = ""
    @State private var showingSyslogSpeedSelector = false
    private let appLogRefreshInterval: TimeInterval = 3.0
    private let syslogIntervalOptions: [Double] = [0.0, 0.2, 0.5, 1.0, 1.5, 2.0]


    private var filteredSyslogEntries: [SystemLogStream.Entry] {
        if syslogSearchText.isEmpty {
            return systemLogStream.entries
        }
        let query = syslogSearchText.lowercased()
        return systemLogStream.entries.filter { $0.searchableRaw.contains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if selectedConsoleTab == .idevice {
                    jitLogsPane
                } else {
                    syslogLogsPane
                }
            }
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $selectedConsoleTab) {
                        Text("App").tag(ConsoleTab.idevice)
                        Text("System").tag(ConsoleTab.syslog)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if selectedConsoleTab == .idevice {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await loadIdeviceLogsAsync() }
                            }
                            Button("Clear", systemImage: "trash", role: .destructive) {
                                logManager.clearLogs()
                            }
                            Button("Copy Logs", systemImage: "doc.on.doc") {
                                copyJITLogs()
                            }
                            exportMenuOption
                        } else {
                            Button(syslogControlLabel, systemImage: syslogControlIcon) {
                                toggleSyslogPlayback()
                            }
                            Button("Clear", systemImage: "trash", role: .destructive) {
                                systemLogStream.clear()
                            }
                            Button("Copy Logs", systemImage: "doc.on.doc") {
                                copySyslogToClipboard()
                            }
                            Button("Adjust Speed", systemImage: "slider.horizontal.3") {
                                showingSyslogSpeedSelector = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert(alertTitle, isPresented: $showingCustomAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .confirmationDialog("日志速度", isPresented: $showingSyslogSpeedSelector) {
                ForEach(syslogIntervalOptions, id: \.self) { option in
                    Button(intervalLabel(for: option)) {
                        systemLogStream.updateInterval = option
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Choose how quickly new relay entries appear.")
            }
        }
                .onDisappear {
            systemLogStream.stop()
        }
        .onChange(of: systemLogStream.lastError) { _, newError in
            if let error = newError {
                presentAlert(title: "Syslog 错误", message: error)
                systemLogStream.lastError = nil
            }
        }
    }
    
    private var jitLogsPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("=== DEVICE INFORMATION ===")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .padding(.vertical, 4)

                        Text(String(format: "iOS Version: %@".localized, UIDevice.current.systemVersion))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)

                        Text(String(format: "Device: %@".localized, UIDevice.current.name))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)

                        Text(String(format: "Model: %@".localized, UIDevice.current.model))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)

                        Text("=== LOG ENTRIES ===")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .padding(.vertical, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                    ForEach(logManager.logs) { logEntry in
                        AppLogRow(logEntry: logEntry, colorScheme: colorScheme)
                            .equatable()
                            .id(logEntry.id)
                    }
                }
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: geometry.frame(in: .named("jitScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "jitScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                updateJITBottomState(offset > -20)
            }
            .onChange(of: logManager.logs.count) { _, _ in
                guard jitIsAtBottom, let lastLog = logManager.logs.last else { return }
                withAnimation {
                    proxy.scrollTo(lastLog.id, anchor: .bottom)
                }
            }
            .onAppear {
                jitScrollView = proxy
                isViewActive = true
                Task { await loadIdeviceLogsAsync() }
                startLogCheckTimer()
            }
            .onDisappear {
                isViewActive = false
                stopLogCheckTimer()
            }
        }
    }
    
    private var syslogLogsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("过滤日志", text: $syslogSearchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !syslogSearchText.isEmpty {
                    Button {
                        syslogSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredSyslogEntries) { entry in
                            SyslogRow(entry: entry, colorScheme: colorScheme)
                                .equatable()
                                .id(entry.id)
                        }
                    }
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geometry.frame(in: .named("syslogScroll")).minY
                            )
                        }
                    )
                }
                .coordinateSpace(name: "syslogScroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                    updateSyslogBottomState(offset > -20)
                }
                .onChange(of: systemLogStream.entries.count) { _, _ in
                    guard syslogIsAtBottom, syslogSearchText.isEmpty,
                          let lastLog = systemLogStream.entries.last else { return }
                    withAnimation {
                        proxy.scrollTo(lastLog.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if selectedConsoleTab == .syslog && !systemLogStream.isStreaming {
                        systemLogStream.start()
                    }
                }
                .onDisappear {
                    systemLogStream.stop()
                }
            }
        }
    }

    private func copyJITLogs() {
        var logsContent = "=== DEVICE INFORMATION ===\n"
        logsContent += "Version: \(UIDevice.current.systemVersion)\n"
        logsContent += "Name: \(UIDevice.current.name)\n"
        logsContent += "Model: \(UIDevice.current.model)\n"
        logsContent += "StikDebug Version: App Version: 1.0\n\n"
        logsContent += "=== LOG ENTRIES ===\n"
        logsContent += logManager.logs.map {
            "[\(formatTime(date: $0.timestamp))] [\($0.type.rawValue)] \($0.message)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = logsContent
        presentAlert(title: "日志已复制", message: "日志已复制到剪贴板。")
    }

    @ViewBuilder
    private var exportMenuOption: some View {
        let logURL = IdeviceLogFileManager.logURL
        if FileManager.default.fileExists(atPath: logURL.path) {
            ShareLink(
                item: logURL,
                preview: SharePreview("idevice_log.txt", image: Image(systemName: "doc.text"))
            ) {
                Label("Export Logs", systemImage: "square.and.arrow.up")
            }
        } else {
            Button("Export Logs", systemImage: "square.and.arrow.up") {
                presentAlert(title: "导出失败", message: "未找到设备日志")
            }
        }
    }
    
    private func formatTime(date: Date) -> String {
        DateFormatter.consoleLogsFormatter.string(from: date)
    }

    nonisolated private static func logType(for line: String) -> LogManager.LogEntry.LogType {
        let lowercase = line.lowercased()
        if lowercase.contains("error") {
            return .error
        } else if lowercase.contains("warning") {
            return .warning
        } else if lowercase.contains("debug") {
            return .debug
        } else {
            return .info
        }
    }

    private func intervalLabel(for value: Double) -> String {
        if value <= 0 {
            return "Live"
        }
        return "\(String(format: "%.1f", value))s"
    }
    
    private func loadIdeviceLogsAsync() async {
        guard !isLoadingLogs else { return }
        isLoadingLogs = true

        let logPath = IdeviceLogFileManager.logURL.path

        guard FileManager.default.fileExists(atPath: logPath) else {
            await MainActor.run {
                logManager.addInfoLog("未找到设备日志（重启应用以继续读取）")
                isLoadingLogs = false
            }
            return
        }

        // Do all file I/O and parsing on a background thread
        let result: ([LogManager.LogEntry], Int)? = await Task.detached(priority: .userInitiated) {
            do {
                let logContent = try String(contentsOfFile: logPath, encoding: .utf8)
                let lines = logContent.components(separatedBy: .newlines)

                let maxLines = 500
                let startIndex = max(0, lines.count - maxLines)
                let recentLines = lines[startIndex..<lines.count]

                let skipPrefixes = ["=== DEVICE INFORMATION ===", "Version:", "Name:", "Model:", "=== LOG ENTRIES ==="]

                let parsed = Self.parseAppLogEntries(from: recentLines, skipPrefixes: skipPrefixes)
                return (parsed, lines.count)
            } catch {
                return nil
            }
        }.value

        await MainActor.run {
            if let (entries, lineCount) = result {
                lastProcessedLineCount = lineCount
                logManager.setLogs(entries)
                if jitIsAtBottom, let last = logManager.logs.last {
                    jitScrollView?.scrollTo(last.id, anchor: .bottom)
                }
            } else {
                logManager.addErrorLog("读取设备日志失败")
            }
            isLoadingLogs = false
        }
    }
    
    private func startLogCheckTimer() {
        guard logCheckTimer == nil else { return }
        logCheckTimer = Timer.scheduledTimer(withTimeInterval: appLogRefreshInterval, repeats: true) { _ in
            if isViewActive {
                Task { await checkForNewLogs() }
            }
        }
        if let logCheckTimer {
            RunLoop.main.add(logCheckTimer, forMode: .common)
        }
    }
    
    private func checkForNewLogs() async {
        guard !isLoadingLogs else { return }
        isLoadingLogs = true

        let logPath = IdeviceLogFileManager.logURL.path
        let previousCount = lastProcessedLineCount

        guard FileManager.default.fileExists(atPath: logPath) else {
            isLoadingLogs = false
            return
        }

        // Parse new lines on a background thread
        let result: ([LogManager.LogEntry], Int)? = await Task.detached(priority: .userInitiated) {
            do {
                let logContent = try String(contentsOfFile: logPath, encoding: .utf8)
                let lines = logContent.components(separatedBy: .newlines)

                guard lines.count > previousCount else { return ([], lines.count) }

                let newLines = lines[previousCount..<lines.count]
                let parsed = Self.parseAppLogEntries(from: newLines)
                return (parsed, lines.count)
            } catch {
                return nil
            }
        }.value

        await MainActor.run {
            if let (entries, lineCount) = result {
                lastProcessedLineCount = lineCount
                if !entries.isEmpty {
                    logManager.appendLogs(entries, maxTotal: 500)
                    if jitIsAtBottom, let last = logManager.logs.last {
                        jitScrollView?.scrollTo(last.id, anchor: .bottom)
                    }
                }
            } else {
                logManager.addErrorLog("读取新日志失败")
            }
            isLoadingLogs = false
        }
    }
    
    private func stopLogCheckTimer() {
        logCheckTimer?.invalidate()
        logCheckTimer = nil
    }

    private func toggleSyslogPlayback() {
        if !systemLogStream.isStreaming {
            systemLogStream.start()
        } else {
            systemLogStream.togglePause()
        }
    }

    private func copySyslogToClipboard() {
        let entries = filteredSyslogEntries
        guard !entries.isEmpty else {
            let message = syslogSearchText.isEmpty ? "无可复制日志条目。" : "无匹配日志条目可复制。"
            presentAlert(title: "导出失败", message: message)
            return
        }

        let content = entries.map { entry in
            "[\(DateFormatter.consoleLogsFormatter.string(from: entry.timestamp))] \(entry.raw)"
        }.joined(separator: "\n")

        UIPasteboard.general.string = content
        let message = syslogSearchText.isEmpty
            ? "最新日志条目已复制到剪贴板。"
            : "\(entries.count) filtered syslog entries copied to clipboard."
        presentAlert(title: "日志已复制", message: message)
    }

    private var syslogControlIcon: String {
        if !systemLogStream.isStreaming || systemLogStream.isPaused {
            return "play.fill"
        }
        return "pause.fill"
    }

    private var syslogControlLabel: String {
        if !systemLogStream.isStreaming {
            return "启动日志中继"
        }
        return systemLogStream.isPaused ? "恢复日志流" : "暂停日志流"
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showingCustomAlert = true
    }

    private func updateJITBottomState(_ isAtBottom: Bool) {
        guard jitIsAtBottom != isAtBottom else { return }
        jitIsAtBottom = isAtBottom
    }

    private func updateSyslogBottomState(_ isAtBottom: Bool) {
        guard syslogIsAtBottom != isAtBottom else { return }
        syslogIsAtBottom = isAtBottom
    }

    nonisolated private static func parseAppLogEntries<S: Sequence>(from lines: S, skipPrefixes: [String] = []) -> [LogManager.LogEntry] where S.Element == String {
        var parsed: [LogManager.LogEntry] = []
        parsed.reserveCapacity(lines.underestimatedCount)

        for line in lines {
            if line.isEmpty { continue }
            if skipPrefixes.contains(where: { line.contains($0) }) { continue }
            parsed.append(LogManager.LogEntry(timestamp: Date(), type: Self.logType(for: line), message: line))
        }
        return parsed
    }

}


struct ConsoleLogsView_Previews: PreviewProvider {
    static var previews: some View {
        ConsoleLogsView()
    }
}

private struct AppLogRow: View, Equatable {
    let logEntry: LogManager.LogEntry
    let colorScheme: ColorScheme

    static func == (lhs: AppLogRow, rhs: AppLogRow) -> Bool {
        lhs.logEntry.id == rhs.logEntry.id && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        Text(AttributedString(attributedString))
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
    }

    private var attributedString: NSAttributedString {
        let fullString = NSMutableAttributedString()

        fullString.append(NSAttributedString(
            string: "[\(DateFormatter.consoleLogsFormatter.string(from: logEntry.timestamp))]",
            attributes: [.foregroundColor: secondaryTextColor]
        ))
        fullString.append(NSAttributedString(string: " "))
        fullString.append(NSAttributedString(
            string: "[\(logEntry.type.rawValue)]",
            attributes: [.foregroundColor: UIColor(logEntry.type.consoleColor)]
        ))
        fullString.append(NSAttributedString(string: " "))
        fullString.append(NSAttributedString(
            string: logEntry.message,
            attributes: [.foregroundColor: primaryTextColor]
        ))

        return fullString
    }

    private var primaryTextColor: UIColor {
        colorScheme == .dark ? .white : .black
    }

    private var secondaryTextColor: UIColor {
        colorScheme == .dark ? .gray : .darkGray
    }
}

private struct SyslogRow: View, Equatable {
    let entry: SystemLogStream.Entry
    let colorScheme: ColorScheme

    static func == (lhs: SyslogRow, rhs: SyslogRow) -> Bool {
        lhs.entry.id == rhs.entry.id && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        Text(AttributedString(attributedString))
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
    }

    private var attributedString: NSAttributedString {
        let type = logType(for: entry.raw)
        let fullString = NSMutableAttributedString()

        fullString.append(NSAttributedString(
            string: "[\(DateFormatter.consoleLogsFormatter.string(from: entry.timestamp))]",
            attributes: [.foregroundColor: secondaryTextColor]
        ))
        fullString.append(NSAttributedString(string: " "))
        fullString.append(NSAttributedString(
            string: "[\(type.rawValue)]",
            attributes: [.foregroundColor: UIColor(type.consoleColor)]
        ))
        fullString.append(NSAttributedString(string: " "))
        fullString.append(NSAttributedString(
            string: entry.raw,
            attributes: [.foregroundColor: primaryTextColor]
        ))

        return fullString
    }

    private var primaryTextColor: UIColor {
        colorScheme == .dark ? .white : .black
    }

    private var secondaryTextColor: UIColor {
        colorScheme == .dark ? .gray : .darkGray
    }

    private func logType(for line: String) -> LogManager.LogEntry.LogType {
        let lowercase = line.lowercased()
        if lowercase.contains("error") {
            return .error
        } else if lowercase.contains("warning") {
            return .warning
        } else if lowercase.contains("debug") {
            return .debug
        } else {
            return .info
        }
    }
}

private enum ConsoleTab: Hashable {
    case idevice
    case syslog
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension DateFormatter {
    static let consoleLogsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private extension LogManager.LogEntry.LogType {
    var consoleColor: Color {
        switch self {
        case .info:
            return .green
        case .error:
            return .red
        case .debug:
            return .blue
        case .warning:
            return .orange
        }
    }
}
