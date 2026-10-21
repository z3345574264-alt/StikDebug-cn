import AppIntents
import Foundation

// MARK: - Installed App Entity

struct InstalledAppEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "已安装应用",
        numericFormat: "\(placeholder: .int) apps"
    )
    static var defaultQuery = InstalledAppQuery()

    var id: String // bundle ID
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(id)")
    }
}

struct InstalledAppQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [InstalledAppEntity] {
        let allApps = (try? JITEnableContext.shared.getAppList()) ?? [:]
        return identifiers.compactMap { bundleID in
            guard let name = allApps[bundleID] else { return nil }
            return InstalledAppEntity(id: bundleID, displayName: name)
        }
    }

    func entities(matching string: String) async throws -> [InstalledAppEntity] {
        let all = try await suggestedEntities()
        guard !string.isEmpty else { return all }
        let lower = string.lowercased()
        return all.filter {
            $0.displayName.lowercased().contains(lower) ||
            $0.id.lowercased().contains(lower)
        }
    }

    func suggestedEntities() async throws -> [InstalledAppEntity] {
        await ensureTunnel()
        let allApps = (try? JITEnableContext.shared.getAppList()) ?? [:]
        return allApps.map { InstalledAppEntity(id: $0.key, displayName: $0.value) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: - Running Process Entity

struct RunningProcessEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "运行中的进程",
        numericFormat: "\(placeholder: .int) processes"
    )
    static var defaultQuery = RunningProcessQuery()

    // Use a stable identifier (bundleID or name) so the entity survives PID changes
    var id: String
    var pid: Int
    var displayName: String
    var bundleID: String?

    var displayRepresentation: DisplayRepresentation {
        let subtitle: String
        if let bundleID, !bundleID.isEmpty {
            subtitle = "\(bundleID) — PID \(pid)"
        } else {
            subtitle = "PID \(pid)"
        }
        return DisplayRepresentation(title: "\(displayName)", subtitle: "\(subtitle)")
    }

    /// Resolve the current PID for this process by re-fetching the process list.
    func resolveCurrentPID() -> Int? {
        var err: NSError?
        let entries = ProcessInfoEntry.currentEntries(&err)
        for item in entries {
            // Match by bundle ID first (most stable), then by name
            if let myBundle = bundleID, !myBundle.isEmpty, item.bundleID == myBundle {
                return item.pid
            }
            if item.displayName == displayName {
                return item.pid
            }
        }
        return nil
    }
}

struct RunningProcessQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RunningProcessEntity] {
        // Always fetch fresh so PIDs are current
        await ensureTunnel()
        let all = try fetchProcessEntities()
        let idSet = Set(identifiers)
        return all.filter { idSet.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [RunningProcessEntity] {
        let all = try await suggestedEntities()
        guard !string.isEmpty else { return all }
        let lower = string.lowercased()
        return all.filter {
            $0.displayName.lowercased().contains(lower) ||
            ($0.bundleID?.lowercased().contains(lower) ?? false) ||
            "\($0.pid)".contains(string)
        }
    }

    func suggestedEntities() async throws -> [RunningProcessEntity] {
        await ensureTunnel()
        return try fetchProcessEntities()
    }

    private func fetchProcessEntities() throws -> [RunningProcessEntity] {
        var err: NSError?
        let entries = ProcessInfoEntry.currentEntries(&err)
        if let err { throw err }

        return entries.map { entry in
            RunningProcessEntity(
                id: entry.stableIdentifier,
                pid: entry.pid,
                displayName: entry.displayName,
                bundleID: entry.bundleID
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: - Enable JIT Intent

struct EnableJITIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "启用 JIT"
    static var description = IntentDescription(
        "使用 StikDebug 为已安装应用启用 JIT 编译。",
        categoryName: "StikDebug"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "应用", description: "要启用 JIT 的应用",
               requestValueDialog: "要为哪个应用启用 JIT？")
    var app: InstalledAppEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Enable JIT for \(\.$app)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let bundleID = app?.id else {
            return .result(value: "选择要启用 JIT 的应用。")
        }

        await ensureTunnel()

        var scriptData: Data? = nil
        var scriptName: String? = nil
        if let preferred = ScriptStore.preferredScript(for: bundleID) {
            scriptData = preferred.data
            scriptName = preferred.name
        }

        var callback: DebugAppCallback? = nil
        if ProcessInfo.processInfo.hasTXM, let sd = scriptData {
            let name = scriptName ?? bundleID
            callback = { pid, debugProxyHandle, remoteServerHandle, semaphore in
                let model = RunJSViewModel(
                    pid: Int(pid),
                    debugProxy: debugProxyHandle,
                    remoteServer: remoteServerHandle,
                    semaphore: semaphore
                )
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .intentJSScriptReady,
                        object: nil,
                        userInfo: ["model": model, "scriptData": sd, "scriptName": name]
                    )
                }
                do { try model.runScript(data: sd, name: name) }
                catch {
                    semaphore.signal()
                    LogManager.shared.addErrorLog("脚本错误：\(error.localizedDescription)")
                }
            }
        }

        let logger: LogFunc = { message in
            if let message { LogManager.shared.addInfoLog(message) }
        }

        let target = app?.displayName ?? bundleID
        let success = JITEnableContext.shared.debugApp(withBundleID: bundleID, logger: logger, jsCallback: callback)

        if success {
            LogManager.shared.addInfoLog("已通过快捷指令为 \(target) 启用 JIT")
            return .result(value: "已成功为 \(target) 启用 JIT。")
        } else {
            LogManager.shared.addErrorLog("通过快捷指令为 \(target) 启用 JIT 失败")
            return .result(value: "为 \(target) 启用 JIT 失败。")
        }
    }
}

// MARK: - Kill Process Intent

struct KillProcessIntent: AppIntent {
    static var title: LocalizedStringResource = "结束进程"
    static var description = IntentDescription(
        "使用 StikDebug 结束设备上正在运行的进程。",
        categoryName: "StikDebug"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "进程", description: "要终止的进程",
               requestValueDialog: "要结束哪个进程？")
    var process: RunningProcessEntity?

    @Parameter(title: "进程 ID", description: "指定要结束的 PID，而不是选择进程")
    var pid: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Kill \(\.$process)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let targetPID: Int
        let targetName: String

        if let pid {
            targetPID = pid
            targetName = "PID \(pid)"
            await ensureTunnel()
        } else if let process {
            await ensureTunnel()

            // Always re-resolve to get the current PID — the stored one may be stale
            guard let resolved = process.resolveCurrentPID() else {
                return .result(value: "\(process.displayName) is no longer running.")
            }
            targetPID = resolved
            targetName = process.displayName
        } else {
            return .result(value: "选择进程或提供 PID。")
        }

        var err: NSError?
        let success = KillDeviceProcess(Int32(targetPID), &err)

        if success {
            LogManager.shared.addInfoLog("已通过快捷指令结束 \(targetName)")
            return .result(value: "已成功结束 \(targetName)。")
        } else {
            let reason = err?.localizedDescription ?? "未知错误"
            LogManager.shared.addErrorLog("通过快捷指令结束 \(targetName) 失败：\(reason)")
            return .result(value: "结束 \(targetName) 失败：\(reason)")
        }
    }
}

// MARK: - Shortcuts Provider

struct StikDebugShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: EnableJITIntent(),
            phrases: [
                "Enable JIT for \(\.$app) with \(.applicationName)",
                "Enable JIT for \(\.$app) using \(.applicationName)",
                "Enable JIT for \(\.$app) in \(.applicationName)",
                "\(.applicationName) enable JIT for \(\.$app)",
                "\(.applicationName) enable JIT",
                "Use \(.applicationName) to enable JIT for \(\.$app)",
                "Use \(.applicationName) to enable JIT"
            ],
            shortTitle: "启用 JIT",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: KillProcessIntent(),
            phrases: [
                "Kill \(\.$process) with \(.applicationName)",
                "Kill \(\.$process) using \(.applicationName)",
                "Kill \(\.$process) in \(.applicationName)",
                "\(.applicationName) kill \(\.$process)",
                "\(.applicationName) kill process",
                "Use \(.applicationName) to kill \(\.$process)",
                "Use \(.applicationName) to stop \(\.$process)"
            ],
            shortTitle: "结束进程",
            systemImageName: "xmark.circle.fill"
        )
    }
}

// MARK: - Shared Tunnel Helper

func ensureTunnel() async {
    await MainActor.run {
        markTunnelDisconnected()
        startTunnelInBackground(showErrorUI: false)
    }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}
