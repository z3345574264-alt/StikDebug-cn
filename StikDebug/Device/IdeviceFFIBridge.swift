//
//  IdeviceFFIBridge.swift
//  StikDebug
//
//  Created by Stephen on 2026/3/30.
//

import Foundation
import UIKit
import idevice

private enum IdeviceBridge {
    static let processQueue = DispatchQueue(label: "com.stikdebug.processInspector", qos: .userInitiated)

    static func makeError(
        domain: String = "StikDebug",
        code: Int = -1,
        message: String
    ) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func string(from cString: UnsafePointer<CChar>?) -> String? {
        guard let cString else { return nil }
        return String(validatingUTF8: cString)
    }

    static func consumeFFIError(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
        fallback: String,
        domain: String = "StikDebug"
    ) -> NSError {
        guard let ffiError else {
            return makeError(domain: domain, message: fallback)
        }

        let code = Int(ffiError.pointee.code)
        let detail = string(from: ffiError.pointee.message) ?? fallback
        let message = detail == fallback ? fallback : "\(fallback): \(detail)"
        idevice_error_free(ffiError)
        return makeError(domain: domain, code: code, message: message)
    }

    static func mappedFileData(atPath path: String, description: String) throws -> Data {
        let url = URL(fileURLWithPath: path)

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else {
                throw makeError(message: "\(description) 为空")
            }
            return data
        } catch let error as NSError {
            throw makeError(code: error.code, message: "读取 \(description) 失败：\(error.localizedDescription)")
        }
    }

    static func uint64Value(from plist: plist_t?, fieldName: String) throws -> UInt64 {
        guard let plist else {
            throw makeError(message: "lockdownd 未返回 \(fieldName)")
        }

        var value: UInt64 = 0
        plist_get_uint_val(plist, &value)

        guard value != 0 else {
            throw makeError(message: "解码 \(fieldName) 失败")
        }

        return value
    }

    static func withTunnelHandles<T>(
        for context: JITEnableContext,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        let handles = try activeTunnelHandles(for: context)
        return try body(handles.adapter, handles.handshake)
    }

    static func connectClient(
        fallback: String,
        missingClientMessage: String,
        domain: String = "StikDebug",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws -> OpaquePointer {
        var client: OpaquePointer?
        if let ffiError = connect(&client) {
            throw consumeFFIError(ffiError, fallback: fallback, domain: domain)
        }

        guard let client else {
            throw makeError(domain: domain, message: missingClientMessage)
        }

        return client
    }

    static func withConnectedClient<T>(
        fallback: String,
        missingClientMessage: String,
        domain: String = "StikDebug",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: (OpaquePointer) -> Void,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let client = try connectClient(
            fallback: fallback,
            missingClientMessage: missingClientMessage,
            domain: domain,
            connect: connect
        )
        defer { cleanup(client) }
        return try body(client)
    }

    static func plistDictionaries(adapter: OpaquePointer, handshake: OpaquePointer) throws -> [[String: Any]] {
        try withConnectedClient(
            fallback: "连接安装代理失败",
            missingClientMessage: "安装代理客户端未创建",
            connect: { installation_proxy_connect_rsd(adapter, handshake, $0) },
            cleanup: { installation_proxy_client_free($0) }
        ) { client in
            var rawApps: UnsafeMutableRawPointer?
            var count = 0
            if let ffiError = installation_proxy_get_apps(client, nil, nil, 0, &rawApps, &count) {
                throw consumeFFIError(ffiError, fallback: "获取已安装应用失败")
            }

            guard let rawApps, count > 0 else { return [] }

            let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
            defer {
                for index in 0..<count {
                    plist_free(apps[index])
                }
                idevice_data_free(
                    rawApps.assumingMemoryBound(to: UInt8.self),
                    UInt(count * MemoryLayout<plist_t?>.stride)
                )
            }

            var dictionaries: [[String: Any]] = []
            dictionaries.reserveCapacity(count)

            for index in 0..<count {
                var binaryPlist: UnsafeMutablePointer<CChar>?
                var binaryLength: UInt32 = 0
                let app = apps[index]

                guard plist_to_bin(app, &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                      let binaryPlist,
                      binaryLength > 0 else {
                    continue
                }

                let data = Data(bytes: binaryPlist, count: Int(binaryLength))
                plist_mem_free(binaryPlist)

                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let dictionary = plist as? [String: Any] else {
                    continue
                }

                dictionaries.append(dictionary)
            }

            return dictionaries
        }
    }

    static func appName(from dictionary: [String: Any]) -> String {
        if let displayName = dictionary["CFBundleDisplayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        if let name = dictionary["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return "未知"
    }

    static func hasGetTaskAllow(_ dictionary: [String: Any]) -> Bool {
        guard let entitlements = dictionary["Entitlements"] as? [String: Any] else {
            return false
        }

        if let flag = entitlements["get-task-allow"] as? Bool {
            return flag
        }

        if let flag = entitlements["get-task-allow"] as? NSNumber {
            return flag.boolValue
        }

        return false
    }

    static func isHiddenSystemApp(_ dictionary: [String: Any]) -> Bool {
        guard let applicationType = dictionary["ApplicationType"] as? String,
              applicationType == "System" || applicationType == "HiddenSystemApp" else {
            return false
        }

        if let isHidden = dictionary["IsHidden"] as? Bool, isHidden {
            return true
        }

        if let isHidden = dictionary["IsHidden"] as? NSNumber, isHidden.boolValue {
            return true
        }

        guard let tags = dictionary["SBAppTags"] as? [String] else {
            return false
        }

        return tags.contains("hidden") || tags.contains("hidden-system-app")
    }

    static func appDictionary(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        requireGetTaskAllow: Bool,
        filter: (([String: Any]) -> Bool)? = nil
    ) throws -> [String: String] {
        let dictionaries = try plistDictionaries(adapter: adapter, handshake: handshake)
        var result: [String: String] = [:]
        result.reserveCapacity(dictionaries.count)

        for dictionary in dictionaries {
            if requireGetTaskAllow && !hasGetTaskAllow(dictionary) {
                continue
            }

            if let filter, !filter(dictionary) {
                continue
            }

            guard let bundleID = dictionary["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else {
                continue
            }

            result[bundleID] = appName(from: dictionary)
        }

        return result
    }

    static func activeTunnelHandles(for context: JITEnableContext) throws -> (adapter: OpaquePointer, handshake: OpaquePointer) {
        try context.ensureTunnel()

        guard let adapterHandle = context.adapterHandle,
              let handshakeHandle = context.handshakeHandle else {
            throw makeError(message: "隧道未连接")
        }

        return (adapterHandle, handshakeHandle)
    }
}

extension JITEnableContext {
    func isDeveloperDiskImageMounted() throws -> Bool {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            var cryptexQuerySucceeded = false
            var cryptexQueryError: NSError?
            if DeveloperDiskImageService.usesCryptexDDI {
                var installed: UnsafeMutablePointer<InstalledCryptexC>?
                defer { cryptexd_free_installed_cryptex(installed) }
                if let ffiError = cryptexd_installed_ddi(adapter, handshake, &installed) {
                    cryptexQueryError = IdeviceBridge.consumeFFIError(ffiError, fallback: "查询已安装的 DDI cryptex 失败")
                } else {
                    cryptexQuerySucceeded = true
                    if installed != nil {
                        return true
                    }
                }
            }

            do {
                return try IdeviceBridge.withConnectedClient(
                    fallback: "连接镜像挂载服务失败",
                    missingClientMessage: "镜像挂载客户端未创建",
                    connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                    cleanup: { image_mounter_free($0) }
                ) { client in
                    var devices: UnsafeMutablePointer<plist_t?>?
                    var deviceCount = 0
                    if let error = image_mounter_copy_devices(client, &devices, &deviceCount) {
                        throw IdeviceBridge.consumeFFIError(error, fallback: "获取已挂载设备失败")
                    }
                    if let devices {
                        for index in 0..<deviceCount {
                            plist_free(devices[index])
                        }
                        idevice_data_free(
                            UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                            UInt(deviceCount * MemoryLayout<plist_t?>.stride)
                        )
                    }
                    return deviceCount > 0
                }
            } catch {
                if cryptexQuerySucceeded {
                    return false
                }
                throw cryptexQueryError ?? (error as NSError)
            }
        }
    }

    func installCryptexDDI(from directoryPath: String) throws {
        var assets: OpaquePointer?
        if let ffiError = cryptex1_assets_load(directoryPath, &assets) {
            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "加载 DDI cryptex 资产失败")
        }

        guard let assets else {
            throw IdeviceBridge.makeError(message: "DDI cryptex 资产未加载")
        }
        defer { cryptex1_assets_free(assets) }

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            if let ffiError = cryptexd_install_ddi(adapter, handshake, assets, nil) {
                throw IdeviceBridge.consumeFFIError(ffiError, fallback: "安装 DDI cryptex 失败")
            }
        }
    }

    func mountPersonalDDI(withImagePath imagePath: String, trustcachePath: String, manifestPath: String) throws {
        let imageData = try IdeviceBridge.mappedFileData(atPath: imagePath, description: "开发者磁盘映像")
        let trustcacheData = try IdeviceBridge.mappedFileData(atPath: trustcachePath, description: "developer disk image trust cache")
        let manifestData = try IdeviceBridge.mappedFileData(atPath: manifestPath, description: "developer disk image manifest")

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            let uniqueChipID = try IdeviceBridge.withConnectedClient(
                fallback: "连接 lockdownd 失败",
                missingClientMessage: "lockdownd 客户端未创建",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
                cleanup: { lockdownd_client_free($0) }
            ) { lockdownClient in
                var uniqueChipIDPlist: plist_t?
                if let ffiError = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &uniqueChipIDPlist) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "查询 UniqueChipID 失败")
                }
                defer { plist_free(uniqueChipIDPlist) }
                return try IdeviceBridge.uint64Value(from: uniqueChipIDPlist, fieldName: "UniqueChipID")
            }

            try IdeviceBridge.withConnectedClient(
                fallback: "连接镜像挂载服务失败",
                missingClientMessage: "镜像挂载客户端未创建",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { imageMounterClient in
                let ffiError = imageData.withUnsafeBytes { imageBuffer in
                    trustcacheData.withUnsafeBytes { trustcacheBuffer in
                        manifestData.withUnsafeBytes { manifestBuffer in
                            image_mounter_mount_personalized_rsd(
                                imageMounterClient,
                                adapter,
                                handshake,
                                imageBuffer.bindMemory(to: UInt8.self).baseAddress,
                                imageData.count,
                                trustcacheBuffer.bindMemory(to: UInt8.self).baseAddress,
                                trustcacheData.count,
                                manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                                manifestData.count,
                                nil,
                                uniqueChipID
                            )
                        }
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "挂载个性化 DDI 失败")
                }
            }
        }
    }

    func fetchAllProfiles() throws -> [Data] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "连接 misagent 失败",
                missingClientMessage: "misagent 客户端未创建",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                var profilePointers: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
                var profileLengths: UnsafeMutablePointer<Int>?
                var profileCount = 0

                if let ffiError = misagent_copy_all(misagentClient, &profilePointers, &profileLengths, &profileCount) {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "获取描述文件失败",
                        domain: "profiles"
                    )
                }

                defer {
                    if let profilePointers, let profileLengths {
                        misagent_free_profiles(profilePointers, profileLengths, profileCount)
                    }
                }

                guard let profilePointers, let profileLengths else { return [] }

                var result: [Data] = []
                result.reserveCapacity(profileCount)

                for index in 0..<profileCount {
                    guard let bytes = profilePointers[index] else { continue }
                    result.append(Data(bytes: bytes, count: profileLengths[index]))
                }

                return result
            }
        }
    }

    func removeProfile(withUUID uuid: String) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "连接 misagent 失败",
                missingClientMessage: "misagent 客户端未创建",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                if let ffiError = misagent_remove(misagentClient, uuid) {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "移除描述文件失败",
                        domain: "profiles"
                    )
                }
            }
        }
    }

    func addProfile(_ profile: Data) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "连接 misagent 失败",
                missingClientMessage: "misagent 客户端未创建",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                let ffiError = profile.withUnsafeBytes { rawBuffer in
                    misagent_install(
                        misagentClient,
                        rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                        profile.count
                    )
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "添加描述文件失败",
                        domain: "profiles"
                    )
                }
            }
        }
    }

    func fetchProcessList() throws -> [NSDictionary] {
        try IdeviceBridge.processQueue.sync {
            try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
                try IdeviceBridge.withConnectedClient(
                    fallback: "无法打开 AppService",
                    missingClientMessage: "AppService 客户端未创建",
                    connect: { app_service_connect_rsd(adapter, handshake, $0) },
                    cleanup: { app_service_free($0) }
                ) { appService in
                    var processes: UnsafeMutablePointer<ProcessTokenC>?
                    var count = UInt(0)
                    if let ffiError = app_service_list_processes(appService, &processes, &count) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "获取进程列表失败")
                    }

                    defer {
                        if let processes {
                            app_service_free_process_list(processes, count)
                        }
                    }

                    guard let processes else { return [] }

                    var result: [NSDictionary] = []
                    result.reserveCapacity(Int(count))

                    for index in 0..<Int(count) {
                        let process = processes[index]
                        var dictionary: [String: Any] = ["pid": NSNumber(value: process.pid)]
                        if let executableURL = IdeviceBridge.string(from: process.executable_url) {
                            dictionary["path"] = executableURL
                        }
                        result.append(dictionary as NSDictionary)
                    }

                    return result
                }
            }
        }
    }

    func sendSignal(_ signal: Int32, toProcessWithPID pid: Int32) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "无法打开 AppService",
                missingClientMessage: "AppService 客户端未创建",
                connect: { app_service_connect_rsd(adapter, handshake, $0) },
                cleanup: { app_service_free($0) }
            ) { appService in
                var response: UnsafeMutablePointer<SignalResponseC>?
                let ffiError = app_service_send_signal(appService, UInt32(pid), UInt32(signal), &response)
                defer {
                    if let response {
                        app_service_free_signal_response(response)
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "向进程发送信号 \(signal) 失败")
                }
            }
        }
    }

    func killProcess(withPID pid: Int32) throws {
        try sendSignal(Int32(SIGKILL), toProcessWithPID: pid)
    }

    func getAppList() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: true
            )
        }
    }

    func getAllApps() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: false
            )
        }
    }

    func getHiddenSystemApps() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: false,
                filter: IdeviceBridge.isHiddenSystemApp
            )
        }
    }

    func getSideloadedApps() throws -> [NSDictionary] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.plistDictionaries(adapter: adapter, handshake: handshake)
                .filter { $0["ProfileValidated"] != nil }
                .map { $0 as NSDictionary }
        }
    }

    func getAppIcon(withBundleId bundleId: String) throws -> UIImage {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "连接 SpringBoard 服务失败",
                missingClientMessage: "SpringBoard 服务客户端未创建",
                connect: { springboard_services_connect_rsd(adapter, handshake, $0) },
                cleanup: { springboard_services_free($0) }
            ) { client in
                var rawIconData: UnsafeMutableRawPointer?
                var rawIconLength = 0
                if let ffiError = springboard_services_get_icon(client, bundleId, &rawIconData, &rawIconLength) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "获取应用图标失败")
                }

                guard let rawIconData, rawIconLength > 0 else {
                    throw IdeviceBridge.makeError(message: "应用图标数据为空")
                }

                defer { free(rawIconData) }

                let data = Data(bytes: rawIconData, count: rawIconLength)
                guard let image = UIImage(data: data) else {
                    throw IdeviceBridge.makeError(message: "解码应用图标图像失败")
                }

                return image
            }
        }
    }

    func ideviceInfoInit() throws -> OpaquePointer {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.connectClient(
                fallback: "连接 lockdownd 失败",
                missingClientMessage: "lockdownd 客户端未创建",
                domain: "profiles",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) }
            )
        }
    }

    func ideviceInfoGetXML(withLockdownClient lockdownClient: OpaquePointer?) throws -> UnsafeMutablePointer<CChar>? {
        guard let lockdownClient else { return nil }

        var plistObject: plist_t?
        if let ffiError = lockdownd_get_value(lockdownClient, nil, nil, &plistObject) {
            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "获取设备信息失败")
        }

        guard let plistObject else {
            return nil
        }

        defer { plist_free(plistObject) }

        var xml: UnsafeMutablePointer<CChar>?
        var xmlLength: UInt32 = 0
        guard plist_to_xml(plistObject, &xml, &xmlLength) == PLIST_ERR_SUCCESS,
              let xml,
              xmlLength > 0 else {
            throw IdeviceBridge.makeError(message: "序列化设备信息 plist 失败")
        }

        return xml
    }
}

func FetchDeviceProcessList(_ error: NSErrorPointer) -> [NSDictionary]? {
    do {
        return try JITEnableContext.shared.fetchProcessList()
    } catch let nsError as NSError {
        error?.pointee = nsError
        return nil
    }
}

func KillDeviceProcess(_ pid: Int32, _ error: NSErrorPointer) -> Bool {
    do {
        try JITEnableContext.shared.killProcess(withPID: pid)
        return true
    } catch let nsError as NSError {
        error?.pointee = nsError
        return false
    }
}

struct ProcessInfoEntry: Identifiable {
    let pid: Int
    private let rawPath: String
    let bundleID: String?
    let name: String?

    init?(dictionary: NSDictionary) {
        guard let pidNumber = dictionary["pid"] as? NSNumber else { return nil }
        pid = pidNumber.intValue
        rawPath = dictionary["path"] as? String ?? "未知"
        bundleID = dictionary["bundleID"] as? String
        name = dictionary["name"] as? String
    }

    static func currentEntries(_ error: NSErrorPointer = nil) -> [ProcessInfoEntry] {
        let entries = FetchDeviceProcessList(error) ?? []
        return entries.compactMap(Self.init(dictionary:))
    }

    var id: Int { pid }

    var executablePath: String {
        rawPath.replacingOccurrences(of: "file://", with: "")
    }

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        if let component = executablePath.split(separator: "/").last {
            return String(component)
        }
        return "进程 \(pid)"
    }

    var stableIdentifier: String {
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        return displayName
    }
}

@objcMembers
final class CMSDecoderHelper: NSObject {
    static func decodeCMSData(_ cmsData: Data) throws -> Data {
        guard !cmsData.isEmpty else {
            throw IdeviceBridge.makeError(
                domain: NSCocoaErrorDomain,
                code: NSURLErrorBadURL,
                message: "无效或空的 CMS 载荷"
            )
        }

        let xmlStart = Data("<?xml".utf8)
        let plistEnd = Data("</plist>".utf8)
        let binaryMagic = Data("bplist00".utf8)

        if let startRange = cmsData.range(of: xmlStart),
           let endRange = cmsData.range(of: plistEnd, options: [], in: startRange.lowerBound..<cmsData.endIndex) {
            return cmsData[startRange.lowerBound..<endRange.upperBound]
        }

        if let binaryRange = cmsData.range(of: binaryMagic) {
            return cmsData[binaryRange.lowerBound..<cmsData.endIndex]
        }

        throw IdeviceBridge.makeError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            message: "无法从 CMS 载荷中提取 plist"
        )
    }
}

private enum LocationSimulationStatus {
    static let ok: Int32 = 0
    static let invalidIP: Int32 = 1
    static let pairingRead: Int32 = 2
    static let providerCreate: Int32 = 3
    static let remoteServer: Int32 = 9
    static let locationSimulation: Int32 = 10
    static let locationSet: Int32 = 11
    static let locationClear: Int32 = 12
}

private enum LocationSimulationState {
    static var adapter: OpaquePointer?
    static var handshake: OpaquePointer?
    static var remoteServer: OpaquePointer?
    static var locationSimulation: OpaquePointer?

    static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }
}

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "com.stik.location-sim", qos: .userInitiated)
}

func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    if let locationSimulation = LocationSimulationState.locationSimulation {
        if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(ffiError)
            LocationSimulationState.cleanup()
        } else {
            return LocationSimulationStatus.ok
        }
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(RemotePairingPortResolver.resolve()).bigEndian

    let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    guard inetResult == 1 else {
        return LocationSimulationStatus.invalidIP
    }

    var pairingHandle: OpaquePointer?
    let pairingError = pairingFile.withCString { rp_pairing_file_read($0, &pairingHandle) }
    if let pairingError {
        idevice_error_free(pairingError)
        return LocationSimulationStatus.pairingRead
    }

    guard let pairingHandle else {
        return LocationSimulationStatus.pairingRead
    }

    defer { rp_pairing_file_free(pairingHandle) }

    let providerError = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            tunnel_create_rppairing(
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.stride),
                "StikDebugLocation",
                pairingHandle,
                nil,
                nil,
                &LocationSimulationState.adapter,
                &LocationSimulationState.handshake
            )
        }
    }

    if let providerError {
        idevice_error_free(providerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.providerCreate
    }

    let remoteServerError = remote_server_connect_rsd(
        LocationSimulationState.adapter,
        LocationSimulationState.handshake,
        &LocationSimulationState.remoteServer
    )
    if let remoteServerError {
        idevice_error_free(remoteServerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.remoteServer
    }

    let locationSimulationError = location_simulation_new(
        LocationSimulationState.remoteServer,
        &LocationSimulationState.locationSimulation
    )
    if let locationSimulationError {
        idevice_error_free(locationSimulationError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSimulation
    }

    LocationSimulationState.remoteServer = nil

    let locationSetError = location_simulation_set(
        LocationSimulationState.locationSimulation,
        latitude,
        longitude
    )
    if let locationSetError {
        idevice_error_free(locationSetError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSet
    }

    return LocationSimulationStatus.ok
}

func clear_simulated_location() -> Int32 {
    guard let locationSimulation = LocationSimulationState.locationSimulation else {
        return LocationSimulationStatus.locationClear
    }

    let ffiError = location_simulation_clear(locationSimulation)
    LocationSimulationState.cleanup()

    if let ffiError {
        idevice_error_free(ffiError)
        return LocationSimulationStatus.locationClear
    }

    return LocationSimulationStatus.ok
}
