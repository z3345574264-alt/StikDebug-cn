//
//  AppFeature.swift
//  StikDebug
//

import SwiftUI

enum AppFeature: String, CaseIterable, Identifiable {
    case home
    case scripts
    case tools
    case console
    case deviceInfo = "deviceinfo"
    case profiles
    case processes
    case location
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .home:
            return "应用"
        case .scripts:
            return "脚本"
        case .tools:
            return "工具"
        case .console:
            return "控制台"
        case .deviceInfo:
            return "设备信息"
        case .profiles:
            return "应用到期时间"
        case .processes:
            return "进程"
        case .location:
            return "位置"
        case .settings:
            return "设置"
        }
    }

    var detail: String {
        switch self {
        case .home:
            return "管理已安装应用"
        case .scripts:
            return "管理和运行 JS 脚本"
        case .tools:
            return "访问更多工具"
        case .console:
            return "实时设备日志"
        case .deviceInfo:
            return "查看设备详细元数据"
        case .profiles:
            return "检查应用到期日期"
        case .processes:
            return "查看运行中的应用"
        case .location:
            return "模拟 GPS 位置"
        case .settings:
            return "配置 StikDebug"
        }
    }

    var toolTitle: String {
        switch self {
        case .location:
            return "位置模拟"
        default:
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            return "square.grid.2x2"
        case .scripts:
            return "scroll"
        case .tools:
            return "wrench.and.screwdriver"
        case .console:
            return "terminal"
        case .deviceInfo:
            return "iphone.and.arrow.forward"
        case .profiles:
            return "calendar.badge.clock"
        case .processes:
            return "rectangle.stack.person.crop"
        case .location:
            return "location"
        case .settings:
            return "gearshape.fill"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .home:
            HomeView()
        case .scripts:
            ScriptListView()
        case .tools:
            ToolsView()
        case .console:
            ConsoleLogsView()
        case .deviceInfo:
            DeviceInfoView()
        case .profiles:
            ProfileView()
        case .processes:
            ProcessInspectorView()
        case .location:
            LocationSimulationView()
        case .settings:
            SettingsView()
        }
    }
}

extension AppFeature {
    static let mainTabs: [AppFeature] = [.home, .tools, .settings]
    static let toolList: [AppFeature] = [.scripts, .console, .deviceInfo, .profiles, .processes, .location]
}
