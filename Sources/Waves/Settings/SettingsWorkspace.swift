import AppKit
import Observation

@Observable
@MainActor
final class SettingsWorkspace {
  var selection: SettingsPane
  let controlDraft = ControlSettingsDraft()

  init(selection: SettingsPane = .general) {
    self.selection = selection
  }
}

@Observable
@MainActor
final class ControlSettingsDraft {
  private(set) var pendingAppIDs: [String] = []
  private(set) var recordingAction: HotkeyAction?
  var liveModifiers: NSEvent.ModifierFlags = []
  private var preservesRecordingDuringPaneReplacement = false

  func addPendingApp(_ appID: String) {
    guard !pendingAppIDs.contains(appID) else { return }
    pendingAppIDs.append(appID)
  }

  func removePendingApp(_ appID: String) {
    pendingAppIDs.removeAll { $0 == appID }
  }

  @discardableResult
  func beginRecording(_ action: HotkeyAction) -> Bool {
    let wasInactive = recordingAction == nil
    recordingAction = action
    liveModifiers = []
    return wasInactive
  }

  func beginPaneReplacement() {
    preservesRecordingDuringPaneReplacement = recordingAction != nil
  }

  func finishPaneReplacement() {
    preservesRecordingDuringPaneReplacement = false
  }

  func shouldPreserveResponderCancellation(for action: HotkeyAction) -> Bool {
    preservesRecordingDuringPaneReplacement && recordingAction == action
  }

  @discardableResult
  func finishRecording(_ action: HotkeyAction) -> Bool {
    guard recordingAction == action else { return false }
    recordingAction = nil
    liveModifiers = []
    preservesRecordingDuringPaneReplacement = false
    return true
  }

  @discardableResult
  func cancelRecording() -> Bool {
    guard recordingAction != nil else { return false }
    recordingAction = nil
    liveModifiers = []
    preservesRecordingDuringPaneReplacement = false
    return true
  }
}
