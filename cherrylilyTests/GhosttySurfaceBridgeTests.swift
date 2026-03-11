import GhosttyKit
import Testing

@testable import CherryLily

@MainActor
struct GhosttySurfaceBridgeTests {
  @Test func bellRangEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var bellCount = 0
    bridge.onBellRang = {
      bellCount += 1
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_RING_BELL
    let target = ghostty_target_s()
    _ = bridge.handleAction(target: target, action: action)

    #expect(bellCount == 1)
    #expect(bridge.state.bellCount == 1)
  }

  @Test func desktopNotificationEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var received: (String, String)?
    bridge.onDesktopNotification = { title, body in
      received = (title, body)
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
    let target = ghostty_target_s()

    "Title".withCString { titlePtr in
      "Body".withCString { bodyPtr in
        action.action.desktop_notification = ghostty_action_desktop_notification_s(
          title: titlePtr,
          body: bodyPtr
        )
        _ = bridge.handleAction(target: target, action: action)
      }
    }

    #expect(received?.0 == "Title")
    #expect(received?.1 == "Body")
  }
}
