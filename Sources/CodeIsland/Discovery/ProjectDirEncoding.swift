import Foundation

/// Encode a path the same way Claude Code does for project directory names:
/// "/" → "-", non-ASCII → "-", spaces → "-"
extension String {
    func claudeProjectDirEncoded() -> String {
        var result = ""
        for c in self.unicodeScalars {
            if c == "/" || c == " " || c.value > 127 {
                result.append("-")
            } else {
                result.append(Character(c))
            }
        }
        return result
    }

    func appProjectDirEncoded() -> String {
        let encoded = claudeProjectDirEncoded()
        if encoded.hasPrefix("-") {
            return String(encoded.dropFirst())
        }
        return encoded
    }
}
