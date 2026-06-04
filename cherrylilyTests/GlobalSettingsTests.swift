import Foundation
import Testing

@testable import CherryLily

struct GlobalSettingsDecodeTests {
  private struct DecodeFailure: Error {}

  private func encodedDictionary(
    defaultEditorID: String,
    includePins: Bool
  ) throws -> [String: Any] {
    var settings = GlobalSettings.default
    settings.defaultEditorID = defaultEditorID
    let data = try JSONEncoder().encode(settings)
    guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw DecodeFailure()
    }
    if !includePins {
      dict.removeValue(forKey: "pinnedToolbarActions")
    }
    return dict
  }

  private func decode(_ dict: [String: Any]) throws -> GlobalSettings {
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(GlobalSettings.self, from: data)
  }

  @Test func decodeAbsentPinsSeedsFinderAndConcreteEditor() throws {
    let dict = try encodedDictionary(defaultEditorID: "zed", includePins: false)
    let settings = try decode(dict)
    #expect(settings.pinnedToolbarActions == ["finder", "zed"])
  }

  @Test func decodeAbsentPinsAutoEditorSeedsFinderAndEditor() throws {
    let dict = try encodedDictionary(defaultEditorID: "auto", includePins: false)
    let settings = try decode(dict)
    #expect(settings.pinnedToolbarActions == ["finder", "editor"])
  }

  @Test func decodePresentEmptyPinsIsRespected() throws {
    var dict = try encodedDictionary(defaultEditorID: "auto", includePins: true)
    dict["pinnedToolbarActions"] = [String]()
    let settings = try decode(dict)
    #expect(settings.pinnedToolbarActions == [])
  }

  @Test func roundTripPreservesPins() throws {
    var settings = GlobalSettings.default
    settings.pinnedToolbarActions = ["finder", "cursor", "custom.foo"]
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(decoded.pinnedToolbarActions == ["finder", "cursor", "custom.foo"])
  }
}
