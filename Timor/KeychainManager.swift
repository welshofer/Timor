//
//  KeychainManager.swift
//  Timor
//
//  Secure storage for Spotify credentials with enhanced access control
//

import Foundation
import Security
import os.log

class KeychainManager {
    static let shared = KeychainManager()

    private static let logger = Logger(subsystem: "com.timor.spotify", category: "KeychainManager")

    private let service = Constants.Keychain.service

    private init() {}

    enum KeychainError: Error, LocalizedError {
        case itemNotFound
        case duplicateItem
        case invalidData
        case accessControlCreationFailed
        case unhandledError(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "Keychain item not found"
            case .duplicateItem:
                return "Keychain item already exists"
            case .invalidData:
                return "Invalid data format"
            case .accessControlCreationFailed:
                return "Failed to create access control"
            case .unhandledError(let status):
                return "Keychain error: \(status)"
            }
        }
    }

    /// Protection level for keychain items
    enum ProtectionLevel {
        /// Standard protection - accessible when device is unlocked
        case standard
        /// High protection - accessible only on this device when unlocked
        case high
        /// Sensitive protection - requires user presence (biometrics) on this device
        case sensitive
    }

    /// Save a value to keychain with specified protection level
    func save(_ value: String, for key: String, protection: ProtectionLevel = .standard) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // Determine accessibility based on protection level
        let accessibility: CFString
        var accessControl: SecAccessControl?

        switch protection {
        case .standard:
            accessibility = kSecAttrAccessibleWhenUnlocked
        case .high:
            accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .sensitive:
            // Create access control requiring user presence
            var error: Unmanaged<CFError>?
            accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &error
            )
            if accessControl == nil {
                Self.logger.error("Failed to create access control: \(error?.takeRetainedValue().localizedDescription ?? "unknown", privacy: .public)")
                // Fall back to high protection if biometrics unavailable
                accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            } else {
                accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]

        // Add access control if created
        if let accessControl = accessControl {
            query[kSecAttrAccessControl as String] = accessControl
            query.removeValue(forKey: kSecAttrAccessible as String) // Can't use both
        }

        // Try to delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            Self.logger.error("Failed to save keychain item '\(key, privacy: .public)': \(status)")
            throw KeychainError.unhandledError(status: status)
        }

        Self.logger.debug("Saved keychain item '\(key, privacy: .public)' with \(String(describing: protection)) protection")
    }

    /// Legacy save method for backwards compatibility
    func save(_ value: String, for key: String) throws {
        // Determine protection level based on key type
        let protection: ProtectionLevel
        switch key {
        case Constants.Keychain.clientSecretKey, Constants.Keychain.refreshTokenKey:
            protection = .high  // Sensitive credentials get high protection
        default:
            protection = .standard
        }
        try save(value, for: key, protection: protection)
    }

    func retrieve(for key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            Self.logger.warning("Failed to retrieve keychain item '\(key, privacy: .public)': \(status)")
            throw KeychainError.unhandledError(status: status)
        }

        guard let data = dataTypeRef as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return value
    }

    func delete(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            Self.logger.error("Failed to delete keychain item '\(key, privacy: .public)': \(status)")
            throw KeychainError.unhandledError(status: status)
        }

        Self.logger.debug("Deleted keychain item '\(key, privacy: .public)'")
    }

    /// Check if a keychain item exists without retrieving it
    func exists(for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Delete all keychain items for this service
    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }

        Self.logger.info("Deleted all keychain items for service")
    }
}