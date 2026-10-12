// Posts a notification with the given title and message.
// Usage: notify <title> <message>
//
// Runs from the app bundle to ensure the notification 
// displays the app icon.

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

// Keeps the process alive until the notification 
// is handed off to the system
let center = UNUserNotificationCenter.current()
let handedOff = DispatchSemaphore(value: 0)
center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in
    handedOff.signal()
}
handedOff.wait()
