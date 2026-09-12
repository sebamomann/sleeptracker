import Foundation

struct SoundLabel: Codable, Hashable, Identifiable {
    var identifier: String
    var confidence: Double
    var id: String {
        identifier
    }

    /// "door_open_or_close" → "Door open or close"
    var display: String {
        let words = identifier.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
