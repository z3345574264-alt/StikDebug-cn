//
//  mountDDI.swift
//  StikDebug
//
//  Created by Stossy11 on 29/03/2025.
//

import Foundation

typealias RpPairingFileHandle = OpaquePointer
typealias AdapterHandle = OpaquePointer
typealias RsdHandshakeHandle = OpaquePointer
typealias ImageMounterHandle = OpaquePointer
typealias LockdowndClientHandle = OpaquePointer

enum MountCheckResult {
    case mounted
    case notMounted
    case unreachable
}

func isMounted() -> Bool {
    return checkMountStatus() == .mounted
}

func checkMountStatus() -> MountCheckResult {
    do {
        return try JITEnableContext.shared.isDeveloperDiskImageMounted() ? .mounted : .notMounted
    } catch {
        LogManager.shared.addErrorLog("检查 DDI 挂载状态失败：\(error.localizedDescription)")
        return .unreachable
    }
}

func mountDeveloperDiskImage(from directoryPath: String) -> String? {
    do {
        if DeveloperDiskImageService.usesCryptexDDI {
            try JITEnableContext.shared.installCryptexDDI(from: directoryPath)
        } else {
            try JITEnableContext.shared.mountPersonalDDI(
                withImagePath: URL(fileURLWithPath: directoryPath).appendingPathComponent("Image.dmg").path,
                trustcachePath: URL(fileURLWithPath: directoryPath).appendingPathComponent("Image.dmg.trustcache").path,
                manifestPath: URL(fileURLWithPath: directoryPath).appendingPathComponent("BuildManifest.plist").path
            )
        }
    } catch {
        return error.localizedDescription
    }
    return nil
}
