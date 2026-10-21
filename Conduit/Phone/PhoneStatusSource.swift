//
//  PhoneStatusSource.swift
//  Conduit
//
//  The phone's current state for Hermes, when the user shares phone status:
//  battery and charging, Low Power Mode, whether CarPlay is connected, where
//  audio is playing (headphones, the car), Wi-Fi or cellular, and what the
//  motion coprocessor last saw (walking, driving…). Latest values only; the
//  host keeps no history of them. Only motion needs a permission.
//

import AVFoundation
import CoreMotion
import Foundation
import Network
import UIKit

@MainActor
protocol PhoneStatusSource: AnyObject {
    /// The `status` object an upload carries (phone-v1-contract.md section 2).
    func snapshot() async -> [String: Any]
    /// Asks for motion access (the system prompt shows once).
    func requestMotionAccess() async
}

@MainActor
final class DevicePhoneStatusSource: PhoneStatusSource {
    private let motion = CMMotionActivityManager()
    private let pathMonitor = NWPathMonitor()
    private var network = "none"
    private var monitoring = false

    /// The network monitor starts with the first snapshot, so it runs only
    /// for people who share phone status.
    private func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let kind = Self.kind(of: path)
            Task { @MainActor in self?.network = kind }
        }
        pathMonitor.start(queue: DispatchQueue(label: "conduit.phone-status.network"))
        network = Self.kind(of: pathMonitor.currentPath)
    }

    nonisolated private static func kind(of path: NWPath) -> String {
        if path.status != .satisfied { return "none" }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        return "wifi"
    }

    deinit {
        pathMonitor.cancel()
    }

    func snapshot() async -> [String: Any] {
        startMonitoring()
        let device = UIDevice.current
        // On only for this read, then back to how it was.
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { if !wasMonitoring { device.isBatteryMonitoringEnabled = false } }
        var value: [String: Any] = [
            "at": PhoneDates.format(Date()),
            "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "carplay": CarPlayVoiceCoordinator.shared.isConnected,
            "audio_route": Self.audioRoute(),
            "network": network,
        ]
        if device.batteryLevel >= 0 {
            value["battery"] = (Double(device.batteryLevel) * 100).rounded() / 100
        }
        switch device.batteryState {
        case .charging, .full: value["charging"] = true
        case .unplugged: value["charging"] = false
        default: break
        }
        if CMMotionActivityManager.authorizationStatus() == .authorized {
            let activity = await latestActivity()
            value["activity"] = activity.kind
            if let confidence = activity.confidence { value["activity_confidence"] = confidence }
        } else {
            value["activity"] = "unknown"
        }
        return value
    }

    func requestMotionAccess() async {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .notDetermined else { return }
        // A query is what makes iOS ask.
        _ = await latestActivity()
    }

    private func latestActivity() async -> (kind: String, confidence: String?) {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() != .denied,
              CMMotionActivityManager.authorizationStatus() != .restricted else { return ("unknown", nil) }
        let now = Date()
        let activities: [CMMotionActivity] = await withCheckedContinuation { continuation in
            motion.queryActivityStarting(from: now.addingTimeInterval(-15 * 60), to: now, to: .main) { found, _ in
                continuation.resume(returning: found ?? [])
            }
        }
        guard let last = activities.last else { return ("unknown", nil) }
        let kind: String
        if last.automotive {
            kind = "automotive"
        } else if last.cycling {
            kind = "cycling"
        } else if last.running {
            kind = "running"
        } else if last.walking {
            kind = "walking"
        } else if last.stationary {
            kind = "stationary"
        } else {
            kind = "unknown"
        }
        let confidence: String
        switch last.confidence {
        case .high: confidence = "high"
        case .medium: confidence = "medium"
        default: confidence = "low"
        }
        return (kind, confidence)
    }

    private static func audioRoute() -> String {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return "other" }
        switch output.portType {
        case .builtInSpeaker: return "speaker"
        case .builtInReceiver: return "receiver"
        case .headphones, .usbAudio: return "headphones"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "bluetooth"
        case .carAudio: return "car"
        case .airPlay: return "airplay"
        default: return "other"
        }
    }
}
