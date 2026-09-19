import AppKit
import Testing
@testable import supacode

@MainActor
struct CommandKeyObserverDelayTests {
  @Test func testDelayBeforeShowingShortcuts() async throws {
    let observer = CommandKeyObserver()
    #expect(observer.isPressed == false)

    observer.handleCommandKeyChange(isDown: true)
    #expect(observer.isPressed == false)
    
    // Wait for 1 second, should still be false
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(observer.isPressed == false)
    
    // Wait for another 1.2 seconds, should become true
    try await Task.sleep(nanoseconds: 1_200_000_000)
    #expect(observer.isPressed == true)

    observer.handleCommandKeyChange(isDown: false)
    #expect(observer.isPressed == false)
  }

  @Test func testDelayIsResetOnMultipleKeyChanges() async throws {
    let observer = CommandKeyObserver()
    #expect(observer.isPressed == false)

    observer.handleCommandKeyChange(isDown: true)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(observer.isPressed == false)

    // Simulate pressing another modifier (e.g. Option) while holding Command
    observer.handleCommandKeyChange(isDown: true)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    // 2.5 seconds total have passed since the first press, but only 1.5s since the second
    #expect(observer.isPressed == false)

    // Wait another 0.6s to cross the 2.0s threshold of the second press
    try await Task.sleep(nanoseconds: 600_000_000)
    #expect(observer.isPressed == true)
  }
}
