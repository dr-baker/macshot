import Foundation

enum BuildVariant {
    static let brandName = "Macshot Pro"
    static let repositoryURL = URL(string: "https://github.com/dr-baker/macshot")!

    #if OFFLINE
    static let isOffline = true
    static let displayName = "Macshot Pro Offline"
    static let updateFeedURL = "https://raw.githubusercontent.com/dr-baker/macshot/main/appcast-offline.xml"
    #else
    static let isOffline = false
    #if LOCAL_DEV
    static let displayName = "Macshot Pro Dev"
    #else
    static let displayName = brandName
    #endif
    static let updateFeedURL = "https://raw.githubusercontent.com/dr-baker/macshot/main/appcast.xml"
    #endif

    static var supportsUpdates: Bool {
        #if LOCAL_DEV
        return false
        #else
        return hasForkUpdateConfiguration(Bundle.main.infoDictionary ?? [:])
        #endif
    }

    /// Source builds omit a signing key. Releases supply the fork's own key.
    static func hasForkUpdateConfiguration(_ info: [String: Any]) -> Bool {
        guard info["SUFeedURL"] as? String == updateFeedURL,
              let key = info["SUPublicEDKey"] as? String,
              let decodedKey = Data(base64Encoded: key), decodedKey.count == 32 else { return false }
        return true
    }
}
