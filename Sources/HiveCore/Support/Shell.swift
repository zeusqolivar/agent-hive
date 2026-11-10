import Foundation

enum Shell {
    private static let unsafe = try! NSRegularExpression(pattern: #"[^A-Za-z0-9_@%+=:,./-]"#)

    /// Python's `shlex.quote`.
    static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if !Text.matches(unsafe, s) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }
}
