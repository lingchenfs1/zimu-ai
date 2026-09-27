import Foundation
import Observation
import Security

/// API Key 只保存在钥匙串中；启动时读取一次缓存在内存里，避免反复访问钥匙串
@MainActor
@Observable
final class APIKeyStore {
    enum Account: String {
        case translation = "translation.apiKey"
        case transcription = "transcription.apiKey"
    }

    var translationKey: String {
        didSet { if translationKey != oldValue { Keychain.write(translationKey, account: Account.translation.rawValue) } }
    }

    var transcriptionKey: String {
        didSet { if transcriptionKey != oldValue { Keychain.write(transcriptionKey, account: Account.transcription.rawValue) } }
    }

    init() {
        translationKey = Keychain.read(account: Account.translation.rawValue)
        transcriptionKey = Keychain.read(account: Account.transcription.rawValue)
    }
}

/// 通用密码钥匙串读写
enum Keychain {
    static let service = "io.github.lingchenfs1.ZimuAI"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(account: String) -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let query = baseQuery(account: account)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "字幕AI \(account)"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
