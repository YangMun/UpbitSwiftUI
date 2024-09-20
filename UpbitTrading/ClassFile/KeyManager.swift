import Foundation

class KeyManager {
    static let shared = KeyManager()
    
    private init() {}
    
    func getAccessKey() -> String? {
        return Bundle.main.object(forInfoDictionaryKey: "UpbitAccessKey") as? String
    }
    
    func getSecretKey() -> String? {
        return Bundle.main.object(forInfoDictionaryKey: "UpbitSecretKey") as? String
    }
    
    func areKeysAvailable() -> Bool {
        guard let accessKey = getAccessKey(),
              let secretKey = getSecretKey(),
              !accessKey.isEmpty,
              !secretKey.isEmpty else {
            return false
        }
        return true
    }
}
