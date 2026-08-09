import AppKit
import Observation

struct ControlRecordingLease: Equatable, Sendable {
  fileprivate let id: UUID
  let action: HotkeyAction
}

struct ControlRecordingAcquisition: Equatable, Sendable {
  let lease: ControlRecordingLease
  let shouldSuspend: Bool
}

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
  private var recordingLease: ControlRecordingLease?
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
    acquireRecording(action).shouldSuspend
  }

  func acquireRecording(_ action: HotkeyAction) -> ControlRecordingAcquisition {
    let acquisition = ControlRecordingAcquisition(
      lease: ControlRecordingLease(id: UUID(), action: action),
      shouldSuspend: recordingLease == nil
    )
    recordingLease = acquisition.lease
    recordingAction = action
    liveModifiers = []
    return acquisition
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

  func activeLease(for action: HotkeyAction) -> ControlRecordingLease? {
    guard recordingAction == action else { return nil }
    return recordingLease
  }

  @discardableResult
  func finishRecording(_ action: HotkeyAction) -> Bool {
    guard recordingAction == action else { return false }
    recordingLease = nil
    recordingAction = nil
    liveModifiers = []
    preservesRecordingDuringPaneReplacement = false
    return true
  }

  @discardableResult
  func finishRecording(_ lease: ControlRecordingLease) -> Bool {
    guard recordingLease == lease else { return false }
    recordingLease = nil
    recordingAction = nil
    liveModifiers = []
    preservesRecordingDuringPaneReplacement = false
    return true
  }

  @discardableResult
  func cancelRecording() -> Bool {
    guard recordingAction != nil else { return false }
    recordingLease = nil
    recordingAction = nil
    liveModifiers = []
    preservesRecordingDuringPaneReplacement = false
    return true
  }
}
