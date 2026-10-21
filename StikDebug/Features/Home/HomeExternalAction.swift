//
//  HomeExternalAction.swift
//  StikDebug
//

import Foundation
import SwiftUI

struct JITEnableConfiguration {
    var bundleID: String?
    var pid: Int?
    var scriptData: Data?
    var scriptName: String?
}

enum HomeExternalAction: Identifiable {
    case enableJIT(JITEnableConfiguration)
    case killProcess(Int)
    case launchApp(String)

    var id: String {
        switch self {
        case .enableJIT(let configuration):
            return "enable-\(configuration.bundleID ?? "")-\(configuration.pid ?? 0)-\(configuration.scriptName ?? "")"
        case .killProcess(let pid):
            return "kill-\(pid)"
        case .launchApp(let bundleID):
            return "launch-\(bundleID)"
        }
    }

    var title: String {
        switch self {
        case .enableJIT:
            return "启用 JIT？"
        case .killProcess:
            return "结束进程？"
        case .launchApp:
            return "启动应用？"
        }
    }

    var message: String {
        switch self {
        case .enableJIT(let configuration):
            let scriptText = configuration.scriptData == nil ? "" : " and run a script"
            return "外部链接想要启用 JIT\(scriptText)，目标为 \(targetDescription(for: configuration))。"
        case .killProcess(let pid):
            return "外部链接想要结束进程 \(pid)。"
        case .launchApp(let bundleID):
            return "外部链接想要启动 \(bundleID)。"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .enableJIT(let configuration):
            return configuration.scriptData == nil ? "启用 JIT" : "启用并运行脚本"
        case .killProcess:
            return "结束进程"
        case .launchApp:
            return "Launch App"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .enableJIT(let configuration):
            return configuration.scriptData == nil ? nil : .destructive
        case .killProcess:
            return .destructive
        case .launchApp:
            return nil
        }
    }

    private func targetDescription(for configuration: JITEnableConfiguration) -> String {
        if let bundleID = configuration.bundleID {
            return bundleID
        }
        if let pid = configuration.pid {
            return "process \(pid)"
        }
        return "所请求的应用"
    }
}
