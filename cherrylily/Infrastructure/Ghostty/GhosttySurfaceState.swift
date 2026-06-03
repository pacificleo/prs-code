import GhosttyKit
import Observation

@MainActor
@Observable
final class GhosttySurfaceState {
  // Observed fields: read by SwiftUI views (progress/search overlays, split-tree
  // leaf, and title/pwd via WorktreeTerminalState). Mutations here invalidate
  // those views.
  var title: String?
  var pwd: String?
  var progressState: ghostty_action_progress_report_state_e?
  var progressValue: Int?
  var searchNeedle: String?
  var searchTotal: Int?
  var searchSelected: Int?
  var searchFocusCount = 0

  // Non-observed fields: written by GhosttySurfaceBridge on high-frequency actions
  // (mouse move, command status, key tables, etc.) and only ever read imperatively
  // by GhosttySurfaceView (an NSView, not a SwiftUI body). Marked @ObservationIgnored
  // so these writes don't churn the observation registrar shared with the fields
  // above — a mouse-move must not invalidate the progress/search overlays.
  @ObservationIgnored var promptTitle: ghostty_action_prompt_title_e?
  @ObservationIgnored var commandExitCode: Int?
  @ObservationIgnored var commandDuration: UInt64?
  @ObservationIgnored var childExitCode: UInt32?
  @ObservationIgnored var childExitTimeMs: UInt64?
  @ObservationIgnored var readOnly: ghostty_action_readonly_e?
  @ObservationIgnored var mouseShape: ghostty_action_mouse_shape_e?
  @ObservationIgnored var mouseVisibility: ghostty_action_mouse_visibility_e?
  @ObservationIgnored var mouseOverLink: String?
  @ObservationIgnored var rendererHealth: ghostty_action_renderer_health_e?
  @ObservationIgnored var openUrl: String?
  @ObservationIgnored var openUrlKind: ghostty_action_open_url_kind_e?
  @ObservationIgnored var colorChangeKind: ghostty_action_color_kind_e?
  @ObservationIgnored var colorChangeR: UInt8?
  @ObservationIgnored var colorChangeG: UInt8?
  @ObservationIgnored var colorChangeB: UInt8?
  @ObservationIgnored var sizeLimitMinWidth: UInt32?
  @ObservationIgnored var sizeLimitMinHeight: UInt32?
  @ObservationIgnored var sizeLimitMaxWidth: UInt32?
  @ObservationIgnored var sizeLimitMaxHeight: UInt32?
  @ObservationIgnored var initialSizeWidth: UInt32?
  @ObservationIgnored var initialSizeHeight: UInt32?
  @ObservationIgnored var keySequenceActive: Bool?
  @ObservationIgnored var keySequenceTrigger: ghostty_input_trigger_s?
  @ObservationIgnored var keyTableTag: ghostty_action_key_table_tag_e?
  @ObservationIgnored var keyTableName: String?
  @ObservationIgnored var keyTableDepth: Int = 0
  @ObservationIgnored var secureInput: ghostty_action_secure_input_e?
  @ObservationIgnored var floatWindow: ghostty_action_float_window_e?
  @ObservationIgnored var reloadConfigSoft: Bool?
  @ObservationIgnored var configChangeCount: Int = 0
  @ObservationIgnored var bellCount: Int = 0
  @ObservationIgnored var openConfigCount: Int = 0
  @ObservationIgnored var presentTerminalCount: Int = 0
  @ObservationIgnored var resetWindowSizeCount: Int = 0
  @ObservationIgnored var quitTimer: ghostty_action_quit_timer_e?
}
