import Testing

struct TelemetryDisabledTests {
  @Test
  func ensureTelemetryDependenciesAreNotLinked() {
    #if canImport(PostHog)
    Issue.record("PostHog dependency was found. It should remain removed from Tuist/Package.swift and Project.swift.")
    #endif

    #if canImport(Sentry)
    Issue.record("Sentry dependency was found. It should remain removed from Tuist/Package.swift and Project.swift.")
    #endif
  }
}
