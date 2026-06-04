import Foundation
import Testing

@testable import CherryLily

struct OpenWorktreeActionTests {
  @Test func menuOrderIncludesExpectedWorkspaceActions() {
    let settingsIDs = OpenWorktreeAction.menuOrder.map(\.settingsID)

    #expect(settingsIDs.contains("antigravity"))
    #expect(settingsIDs.contains("intellij"))
    #expect(settingsIDs.contains("rustrover"))
    #expect(settingsIDs.contains("vscode-insiders"))
    #expect(settingsIDs.contains("warp"))
    #expect(settingsIDs.contains("webstorm"))
    #expect(settingsIDs.contains("pycharm"))
  }

  @Test func jetBrainsIDEsHaveCorrectBundleIdentifiers() {
    #expect(OpenWorktreeAction.intellij.bundleIdentifier == "com.jetbrains.intellij")
    #expect(OpenWorktreeAction.webstorm.bundleIdentifier == "com.jetbrains.WebStorm")
    #expect(OpenWorktreeAction.pycharm.bundleIdentifier == "com.jetbrains.pycharm")
    #expect(OpenWorktreeAction.rustrover.bundleIdentifier == "com.jetbrains.rustrover")
  }

  @Test func jetBrainsIDEsAreInEditorPriority() {
    let editors = OpenWorktreeAction.editorPriority
    #expect(editors.contains(.intellij))
    #expect(editors.contains(.webstorm))
    #expect(editors.contains(.pycharm))
    #expect(editors.contains(.rustrover))
  }

  @Test func pinnedToolbarCasesOrdersAndFiltersUnknown() {
    var settings = GlobalSettings.default
    settings.pinnedToolbarActions = ["finder", "editor", "does-not-exist"]
    let cases = OpenWorktreeAction.pinnedToolbarCases(settings: settings)
    #expect(cases.map(\.settingsID) == ["finder", "editor"])
  }

  @Test func pinnedToolbarCasesResolvesCustomWithIcon() {
    var settings = GlobalSettings.default
    let icon = Data([0x01, 0x02])
    settings.customWorktreeActions = [
      CustomWorktreeAction(
        id: "custom.foo",
        name: "Foo",
        url: URL(filePath: "/Applications/Foo.app"),
        icon: icon
      ),
    ]
    settings.pinnedToolbarActions = ["custom.foo"]
    let cases = OpenWorktreeAction.pinnedToolbarCases(settings: settings)
    #expect(cases.count == 1)
    #expect(cases.first?.settingsID == "custom.foo")
    #expect(cases.first?.customIconData == icon)
  }

  @Test func seededPinnedToolbarActionsHandlesAutoAndConcrete() {
    #expect(OpenWorktreeAction.seededPinnedToolbarActions(defaultEditorID: "auto") == ["finder", "editor"])
    #expect(OpenWorktreeAction.seededPinnedToolbarActions(defaultEditorID: "cursor") == ["finder", "cursor"])
    #expect(OpenWorktreeAction.seededPinnedToolbarActions(defaultEditorID: "finder") == ["finder"])
  }
}
