import AppKit
import Testing

@testable import Waves

@MainActor
@Test func settingsWorkspaceRetainsPendingRowsAndRecorderAcrossPaneNavigation() {
  let workspace = SettingsWorkspace(selection: .control)
  let action = HotkeyAction.muteApp("com.example.app")
  workspace.controlDraft.addPendingApp("com.example.app")
  #expect(workspace.controlDraft.beginRecording(action))
  workspace.controlDraft.liveModifiers = [.command, .option]

  workspace.controlDraft.beginPaneReplacement()
  workspace.selection = .general
  #expect(workspace.controlDraft.shouldPreserveResponderCancellation(for: action))
  workspace.selection = .control
  workspace.controlDraft.finishPaneReplacement()

  #expect(workspace.controlDraft.pendingAppIDs == ["com.example.app"])
  #expect(workspace.controlDraft.recordingAction == action)
  #expect(workspace.controlDraft.liveModifiers == [.command, .option])
}

@MainActor
@Test func settingsWorkspaceCommitAndCancelClearOnlyTheirOwnedDraftState() {
  let draft = ControlSettingsDraft()
  let first = HotkeyAction.muteApp("com.example.first")
  let second = HotkeyAction.muteApp("com.example.second")
  draft.addPendingApp("com.example.first")
  draft.addPendingApp("com.example.second")

  _ = draft.beginRecording(first)
  #expect(draft.finishRecording(first))
  draft.removePendingApp("com.example.first")
  #expect(draft.recordingAction == nil)
  #expect(draft.pendingAppIDs == ["com.example.second"])

  _ = draft.beginRecording(second)
  #expect(draft.cancelRecording())
  #expect(draft.recordingAction == nil)
  #expect(draft.pendingAppIDs == ["com.example.second"])
}
