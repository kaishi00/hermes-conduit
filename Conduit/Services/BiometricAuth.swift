//
//  BiometricAuth.swift
//  Conduit
//

import LocalAuthentication

enum BiometricAuth {
    /// The biometric sensor that can guard a saved credential. Face ID and
    /// Touch ID share one setting and one LocalAuthentication policy; only
    /// the wording changes with the device.
    enum Kind: Equatable {
        case faceID
        case touchID
    }

    /// The sensor this device has, and whether it can guard a credential
    /// right now (something enrolled, not locked out). The kind is known
    /// even when nothing is enrolled, so the wording can still name it.
    struct Status: Equatable {
        var kind: Kind?
        var isAvailable: Bool
    }

    static var status: Status {
        let context = LAContext()
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let kind = kind(for: context.biometryType)
        return Status(kind: kind, isAvailable: canEvaluate && kind != nil)
    }

    static var isAvailable: Bool { status.isAvailable }

    static func kind(for biometryType: LABiometryType) -> Kind? {
        switch biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return nil
        }
    }

    /// Device passcode remains an iOS-provided recovery path after Face ID
    /// or Touch ID cannot authenticate, rather than turning a transient
    /// biometric failure into a permanent app lockout.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
