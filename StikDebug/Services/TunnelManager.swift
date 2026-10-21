//
//  TunnelManager.swift
//  StikDebug
//

import Foundation

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var isConnected = false

    private var isStarting = false
    private var restartPending = false

    private init() {}

    func markDisconnected() {
        runOnMain {
            self.isConnected = false
        }
    }

    func restart() {
        runOnMain {
            self.isConnected = false
            if self.isStarting {
                self.restartPending = true
            } else {
                self.start()
            }
        }
    }

    func start(showErrorUI: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.start(showErrorUI: showErrorUI)
            }
            return
        }

        let pairingFileURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            isConnected = false
            return
        }

        guard !isStarting else {
            return
        }

        isStarting = true

        DispatchQueue.global(qos: .userInteractive).async { [showErrorUI] in
            let result: Result<Void, NSError>
            do {
                try JITEnableContext.shared.startTunnel()
                result = .success(())
            } catch {
                result = .failure(error as NSError)
            }

            DispatchQueue.main.async {
                self.finishStart(result, showErrorUI: showErrorUI)
            }
        }
    }

    private func finishStart(_ result: Result<Void, NSError>, showErrorUI: Bool) {
        isStarting = false
        if restartPending {
            restartPending = false
            start()
            return
        }

        switch result {
        case .success:
            isConnected = true
            LogManager.shared.addInfoLog("隧道连接成功")
            mountDeveloperDiskImageIfNeeded()
        case .failure(let error):
            isConnected = false
            handleStartFailure(error, showErrorUI: showErrorUI)
        }
    }

    private func mountDeveloperDiskImageIfNeeded() {
        guard DeveloperDiskImageService.filesAreReady else { return }
        MountingProgress.shared.pubMount()
    }

    private func handleStartFailure(_ error: NSError, showErrorUI: Bool) {
        LogManager.shared.addErrorLog(tunnelConnectionLogMessage(for: error))
        guard showErrorUI else {
            return
        }

        if error.code == -9 {
            handleInvalidPairingFile()
            return
        }

        showAlert(
            title: "连接错误",
            message: tunnelConnectionAlertMessage(for: error),
            showOk: false,
            showTryAgain: true
        ) { shouldTryAgain in
            if shouldTryAgain {
                startTunnelInBackground()
            }
        }
    }

    private func handleInvalidPairingFile() {
        LogManager.shared.addInfoLog("配对文件无效；保留现有文件")

        showAlert(
            title: "无效配对文件",
            message: "配对文件可能无效或已过期，你可以导入新的配对文件来替换。",
            showOk: true,
            showTryAgain: false,
            primaryButtonText: "选择新文件"
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("ShowPairingFilePicker"), object: nil)
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

func startTunnelInBackground(showErrorUI: Bool = true) {
    TunnelManager.shared.start(showErrorUI: showErrorUI)
}

func markTunnelDisconnected() {
    TunnelManager.shared.markDisconnected()
}

private func tunnelConnectionLogMessage(for error: NSError) -> String {
    let target = RemotePairingPortResolver.lastAttemptDescription
    return "连接 \(target) 的隧道失败：\(error.localizedDescription)（域：\(error.domain)，代码：\(error.code)，原始：\(String(describing: error)))"
}

private func tunnelConnectionAlertMessage(for error: NSError) -> String {
    """
    Target attempted: \(RemotePairingPortResolver.lastAttemptDescription)

    Code \(error.code): \(error.localizedDescription)
    """
}
