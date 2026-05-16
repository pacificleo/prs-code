import Foundation
import Testing

@testable import CherryLily

struct SurfaceIDTests {
  @Test func sessionNameFormatsAsCLPrefix() {
    let uuid = UUID(uuidString: "7C8C2B5E-5D7E-4C7E-9C7E-6C7E7C7E7C7E")!
    let id = SurfaceID(rawValue: uuid)
    #expect(id.tmuxSessionName == "cl_7c8c2b5e-5d7e-4c7e-9c7e-6c7e7c7e7c7e")
  }

  @Test func parsedFromTmuxSessionNameRoundTrips() {
    let id = SurfaceID()
    let name = id.tmuxSessionName
    let parsed = SurfaceID(tmuxSessionName: name)
    #expect(parsed == id)
  }

  @Test func parsedFromInvalidNameReturnsNil() {
    #expect(SurfaceID(tmuxSessionName: "not-a-cherrylily-session") == nil)
    #expect(SurfaceID(tmuxSessionName: "cl_not-a-uuid") == nil)
    #expect(SurfaceID(tmuxSessionName: "") == nil)
  }

  @Test func codableRoundtrip() throws {
    let id = SurfaceID()
    let data = try JSONEncoder().encode(id)
    let decoded = try JSONDecoder().decode(SurfaceID.self, from: data)
    #expect(decoded == id)
  }
}
