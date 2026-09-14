import Foundation
import LocalAuthentication

public enum BiometricError: LocalizedError, Equatable {
    case userCancelled
    case authenticationFailed
    case biometricsNotAvailable(String)

    public var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Authentication was cancelled by the user."
        case .authenticationFailed:
            return "Biometric authentication failed. The expected user was not verified."
        case .biometricsNotAvailable(let msg):
            return "Biometric authentication is unavailable: \(msg)"
        }
    }
}

public enum BiometricAuthService {
    /// Indicates whether biometric authentication (Face ID or Touch ID) is enrolled and available
    public static var isBiometryAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Detected biometry hardware type on the current device
    public static var biometryType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return context.biometryType
    }

    /// User-friendly label for the device's biometric sensor ("Face ID", "Touch ID", etc.)
    public static var biometryName: String {
        switch biometryType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        case .none:
            return "Device Passcode"
        @unknown default:
            return "Biometrics"
        }
    }

    public static var isRunningInTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    @MainActor public private(set) static var isAuthenticating: Bool = false

    /// Prompts the user with Face ID / Touch ID and returns the authenticated LAContext for Keychain access
    @MainActor
    public static func authenticate(reason: String, context: LAContext = LAContext()) async throws -> LAContext {
        context.localizedCancelTitle = "Cancel"

        if isRunningInTests {
            try Task.checkCancellation()
            return context
        }

        if isAuthenticating {
            throw BiometricError.userCancelled
        }

        try Task.checkCancellation()

        isAuthenticating = true
        defer { isAuthenticating = false }

        return try await withTaskCancellationHandler {
            var error: NSError?
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
                do {
                    let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
                    try Task.checkCancellation()
                    guard success else { throw BiometricError.authenticationFailed }
                    return context
                } catch let laError as LAError {
                    if Task.isCancelled || laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel {
                        throw BiometricError.userCancelled
                    }
                    switch laError.code {
                    case .authenticationFailed:
                        throw BiometricError.authenticationFailed
                    default:
                        throw BiometricError.biometricsNotAvailable(laError.localizedDescription)
                    }
                } catch {
                    if Task.isCancelled {
                        throw BiometricError.userCancelled
                    }
                    throw BiometricError.authenticationFailed
                }
            } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
                do {
                    let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                    try Task.checkCancellation()
                    guard success else { throw BiometricError.authenticationFailed }
                    return context
                } catch let laError as LAError {
                    if Task.isCancelled || laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel {
                        throw BiometricError.userCancelled
                    }
                    throw BiometricError.authenticationFailed
                } catch {
                    if Task.isCancelled {
                        throw BiometricError.userCancelled
                    }
                    throw BiometricError.authenticationFailed
                }
            } else {
                #if targetEnvironment(simulator)
                // Headless simulators have no passcode or biometrics; allow so development flows work
                try Task.checkCancellation()
                return context
                #else
                // No passcode is set, so user presence cannot be verified: fail closed
                throw BiometricError.biometricsNotAvailable("No device passcode is set. Set a passcode, or turn off “Require \(biometryName) on Connect” for this host.")
                #endif
            }
        } onCancel: {
            context.invalidate()
        }
    }

    /// Prompts the user with Face ID / Touch ID to verify the expected user is present
    @MainActor
    @discardableResult
    public static func authenticateUser(reason: String) async throws -> Bool {
        _ = try await authenticate(reason: reason)
        return true
    }
}
