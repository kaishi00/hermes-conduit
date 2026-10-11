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

    /// The enrolled sensor on this device, nil when there is none (no
    /// sensor, nothing enrolled, or biometrics locked out).
    static var availableKind: Kind? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return nil
        }
        return kind(for: context.biometryType)
    }

    static var isAvailable: Bool { availableKind != nil }

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
