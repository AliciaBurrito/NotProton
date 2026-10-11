// Posts a macOS notification with the given title and message.
// Usage: notify <title> <message>
//
// The executable runs from inside notify.app, so the notification center
// shows the bundle's icon, which is NotProton's, rather than the plain
// script icon osascript gets. The run script invokes it directly; if the
// user has not allowed notifications yet, the system shows its one-time
// permission prompt on first use.

import Foundation
import UserNotifications

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: notify <title> <message>\n", stderr)
    exit(2)
}

let content = UNMutableNotificationContent()
content.title = args[1]
content.body = args[2]

// The process must stay alive until the system has accepted the request,
// so the hand-off is waited on instead of exiting right after add.
let center = UNUserNotificationCenter.current()
let handedOff = DispatchSemaphore(value: 0)
center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in
    handedOff.signal()
}
handedOff.wait()
