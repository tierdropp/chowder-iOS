import Foundation
import CryptoKit

/// Manages Ed25519 device identity for OpenClaw gateway pairing.
///
/// The keypair is generated once and stored in the Keychain. The public key
/// is sent to the gateway during pairing, and the private key is used to sign
/// challenges for authentication.
///
/// Protocol reference: https://docs.openclaw.ai/gateway/protocol
enum DeviceIdentityService {
    
    // MARK: - Constants
    
    private static let privateKeyTag = "com.chowder.deviceIdentity.ed25519.private"
    private static let publicKeyTag = "com.chowder.deviceIdentity.ed25519.public"
    private static let deviceIdKey = "com.chowder.deviceIdentity.deviceId"
    
    // MARK: - Public Interface
    
    /// Returns the device's Ed25519 public key as a base64-encoded string.
    /// Generates a new keypair if one doesn't exist.
    static var publicKeyBase64: String {
        return getOrCreateKeyPair().publicKeyBase64
    }
    
    /// Returns a stable device identifier derived from the public key.
    /// This is a SHA-256 hash of the public key, truncated to 16 characters.
    static var deviceId: String {
        // Check cache first
        if let cached = UserDefaults.standard.string(forKey: deviceIdKey) {
            return cached
        }
        
        let keypair = getOrCreateKeyPair()
        let hash = SHA256.hash(data: keypair.publicKey.rawRepresentation)
        let deviceId = hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        let result = String(deviceId)
        
        // Cache it
        UserDefaults.standard.set(result, forKey: deviceIdKey)
        
        return result
    }
    
    /// Signs a challenge string using the device's Ed25519 private key.
    /// Returns the signature as a base64-encoded string.
    ///
    /// - Parameter challenge: The challenge nonce from the gateway
    /// - Returns: Base64-encoded Ed25519 signature
    static func sign(challenge: String) -> String {
        let keypair = getOrCreateKeyPair()
        guard let challengeData = challenge.data(using: .utf8) else {
            print("⚠️ [DeviceIdentity] Failed to encode challenge as UTF-8")
            return ""
        }
        
        do {
            let signature = try keypair.privateKey.signature(for: challengeData)
            return signature.rawRepresentation.base64EncodedString()
        } catch {
            print("⚠️ [DeviceIdentity] Failed to sign challenge: \(error)")
            return ""
        }
    }
    
    /// Verifies a signature against a challenge using our public key.
    /// Useful for testing the signing implementation.
    static func verify(signature: String, challenge: String) -> Bool {
        let keypair = getOrCreateKeyPair()
        guard let challengeData = challenge.data(using: .utf8),
              let signatureData = Data(base64Encoded: signature) else {
            return false
        }
        
        do {
            let sig = try Curve25519.Signing.PublicKey.Signature(rawRepresentation: signatureData)
            return keypair.publicKey.isValidSignature(sig, for: challengeData)
        } catch {
            print("⚠️ [DeviceIdentity] Failed to verify signature: \(error)")
            return false
        }
    }
    
    /// Clears the stored keypair. Use with caution — this will require re-pairing.
    static func reset() {
        deleteKey(tag: privateKeyTag)
        deleteKey(tag: publicKeyTag)
        UserDefaults.standard.removeObject(forKey: deviceIdKey)
        print("🔑 [DeviceIdentity] Keypair reset")
    }
    
    // MARK: - Private Implementation
    
    private struct KeyPair {
        let privateKey: Curve25519.Signing.PrivateKey
        let publicKey: Curve25519.Signing.PublicKey
        
        var publicKeyBase64: String {
            publicKey.rawRepresentation.base64EncodedString()
        }
    }
    
    /// Gets the existing keypair from Keychain or creates a new one.
    private static func getOrCreateKeyPair() -> KeyPair {
        // Try to load existing private key
        if let privateKeyData = loadKey(tag: privateKeyTag) {
            do {
                let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
                let publicKey = privateKey.publicKey
                return KeyPair(privateKey: privateKey, publicKey: publicKey)
            } catch {
                print("⚠️ [DeviceIdentity] Failed to load existing key: \(error)")
                // Fall through to create new keypair
            }
        }
        
        // Generate new keypair
        print("🔑 [DeviceIdentity] Generating new Ed25519 keypair")
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        // Store in Keychain
        saveKey(data: privateKey.rawRepresentation, tag: privateKeyTag)
        saveKey(data: publicKey.rawRepresentation, tag: publicKeyTag)
        
        // Clear cached device ID (will be regenerated)
        UserDefaults.standard.removeObject(forKey: deviceIdKey)
        
        return KeyPair(privateKey: privateKey, publicKey: publicKey)
    }
    
    // MARK: - Keychain Helpers
    
    private static func saveKey(data: Data, tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, // Generic key type
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        // Delete any existing key first
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ [DeviceIdentity] Failed to save key to Keychain: \(status)")
        }
    }
    
    private static func loadKey(tag: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        
        return data
    }
    
    private static func deleteKey(tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}
