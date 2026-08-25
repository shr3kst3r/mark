import AppKit
import MarkKit

//
// The app's entry point.
//
// `mark.app/Contents/MacOS/mark` — the first of the two Mach-O executables
// ADR-1 puts in the bundle. The second, `mark-cli`, is the Rust binary and is
// built by cargo; neither knows about the other until M4's socket.
//
// Everything else lives in the `MarkKit` library target so the test target and
// `mark-bench` can import it. This file is the only thing that cannot be.
//

let arguments = CommandLine.arguments.dropFirst()
let launchFiles =
    arguments
    .filter { !$0.hasPrefix("-") }
    .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let delegate = AppDelegate(launchFiles: launchFiles)
application.delegate = delegate
application.run()
