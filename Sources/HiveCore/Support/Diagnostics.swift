import Foundation
#if os(Windows)
import WinSDK
#endif

/// One line of diagnostics to standard error, for the helper's log.
///
/// Foundation's standard-error handle on Windows reaches a console but neither a redirected file nor a pipe, and
/// the shell sends the helper's stderr to `%APPDATA%\Agent Hive\logs\hive-core.log`. Writing to the handle itself
/// works in all three cases. Nothing here may carry a key, a request body, a response body or a message.
public enum Diagnostics {
    public static func write(_ message: String) {
        let data = Data((message + "\n").utf8)
        #if os(Windows)
        var written: DWORD = 0
        let handle = GetStdHandle(STD_ERROR_HANDLE)
        _ = data.withUnsafeBytes { raw in
            WriteFile(handle, raw.baseAddress, DWORD(raw.count), &written, nil)
        }
        #else
        FileHandle.standardError.write(data)
        #endif
    }
}
