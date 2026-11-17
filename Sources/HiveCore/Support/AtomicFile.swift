import Foundation
#if os(Windows)
import WinSDK
#endif

/// Putting a file's new contents in place in one step, so a reader sees the old file or the new one and never
/// half of either.
///
/// This exists because the two systems disagree: `rename(2)` replaces the destination on macOS but fails on
/// Windows when the target already exists, which is exactly the case that matters (settings.json, classroom.json).
public enum AtomicFile {
    /// Why a replace failed, in words that can be shown.
    public struct Failed: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Moves `temp` over `target`, replacing whatever was there.
    public static func replace(_ target: URL, with temp: URL) throws {
        #if os(Windows)
        let flags = DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH)
        let moved = temp.path.withCString(encodedAs: UTF16.self) { from in
            target.path.withCString(encodedAs: UTF16.self) { to in
                MoveFileExW(from, to, flags)
            }
        }
        guard moved else {
            throw Failed(message: "Windows error \(GetLastError())")
        }
        #else
        guard rename(temp.path, target.path) == 0 else {
            throw Failed(message: String(cString: strerror(errno)))
        }
        #endif
    }
}
