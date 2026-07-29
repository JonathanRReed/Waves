import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A click-to-record shortcut field.
///
/// Backed by an `NSView` rather than SwiftUI's key handling because a recorder
/// has to see keystrokes the app would otherwise act on. Menu equivalents —
/// ⌘Q, ⌘W, ⌘, — are dispatched through `performKeyEquivalent(with:)` and never
/// reach `onKeyPress`, so a SwiftUI-only recorder quits Waves when someone
/// tries to record ⌘⌥Q. Overriding that method is what makes every combination
/// recordable.
struct ShortcutRecorder: View {
  @Environment(\.wavesTheme) private var theme
  @Environment(AppStore.self) private var store

  /// The chord currently bound to this row, if any.
  let binding: HotkeyBinding?
  /// Whether the remove button stays available with nothing recorded. True for
  /// rows that exist only because the user added them, where ✕ means "take this
  /// row back" rather than "clear this shortcut".
  var canRemoveWhenUnset = false
  /// The system refused this chord, so the shortcut is registered nowhere and
  /// will never fire. Drawn as a warning rather than as an ordinary shortcut.
  var isUnavailable = false
  /// Records a chord. Return a message to show if it was refused, or nil if it
  /// was accepted — the recorder stays open on refusal so the next attempt does
  /// not need another click.
  let onRecord: (HotkeyChord) -> String?
  let onClear: () -> Void

  @State private var isRecording = false
  @State private var liveModifiers: NSEvent.ModifierFlags = []
  @State private var message: String?

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      HStack(spacing: 6) {
        Button {
          if isRecording { stop() } else { start() }
        } label: {
          Text(fieldText)
            .font(.system(.body, design: isRecording ? .default : .monospaced))
            .foregroundStyle(fieldTextStyle)
            .frame(minWidth: 96)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(fieldBackground)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
          // Zero-size and behind the button: this exists only to hold first
          // responder while recording.
          ShortcutCaptureView(
            isRecording: $isRecording,
            liveModifiers: $liveModifiers,
            onChord: record,
            onClear: {
              onClear()
              stop()
            },
            onCancel: stop
          )
          .frame(width: 0, height: 0)
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
          isRecording
            ? "Type a key combination, or press Escape to cancel."
            : "Records a new keyboard shortcut."
        )

        Button {
          onClear()
          stop()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .opacity(showsRemove ? 1 : 0)
        .disabled(!showsRemove)
        .accessibilityLabel(binding == nil ? "Remove row" : "Remove shortcut")
      }

      if let note = message ?? unavailableNote {
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 260, alignment: .trailing)
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.15), value: message)
    .onChange(of: message) { _, new in
      // VoiceOver does not read a caption that simply appears, so a refusal
      // would be completely silent — the user hears nothing, the field stays
      // open, and nothing explains why their chord didn't take.
      guard let new else { return }
      AccessibilityNotification.Announcement(new).post()
    }
    .onDisappear(perform: stop)
  }

  /// Shown when the row holds a chord the system refused. Not an error the user
  /// just caused, so it sits quietly under the row rather than announcing
  /// itself — but it must be there, or a dead shortcut looks exactly like a
  /// working one forever.
  private var unavailableNote: String? {
    guard isUnavailable, !isRecording else { return nil }
    return "macOS or another app already uses this. Pick another combination."
  }

  private func record(_ chord: HotkeyChord) {
    if let failure = onRecord(chord) {
      message = failure
      // Stay open: the whole point of a refusal is that another chord follows.
    } else {
      message = nil
      stop()
    }
  }

  private func start() {
    message = nil
    liveModifiers = []
    isRecording = true
    // Release Waves's own registrations for the duration. Without this, every
    // chord Waves already holds is swallowed by the system and fires its action
    // instead of being recorded — so ⌘⌥M could never be moved or re-recorded,
    // and pressing an app's existing chord would mute that app mid-typing.
    store.setHotkeysSuspended(true)
  }

  /// The single exit from recording. Every path — committing, cancelling,
  /// clearing, clicking away, the view disappearing — must come through here,
  /// because a missed resume leaves the user with no global shortcuts at all
  /// and nothing on screen to explain it.
  private func stop() {
    let wasRecording = isRecording
    isRecording = false
    liveModifiers = []
    if wasRecording {
      store.setHotkeysSuspended(false)
    }
  }

  private var showsRemove: Bool {
    guard !isRecording else { return false }
    return binding != nil || canRemoveWhenUnset
  }

  private var fieldText: String {
    guard isRecording else { return binding?.displayString ?? "Not set" }
    let preview = HotkeyFormatter.modifierString(
      carbon: HotkeyModifiers.carbon(from: liveModifiers)
    )
    return preview.isEmpty ? "Type a shortcut" : preview + "…"
  }

  private var fieldTextStyle: AnyShapeStyle {
    if isRecording { return AnyShapeStyle(theme.accent) }
    if isUnavailable { return AnyShapeStyle(.orange) }
    return AnyShapeStyle(binding == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
  }

  private var fieldBackground: some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(isRecording ? AnyShapeStyle(theme.accent.opacity(0.12)) : AnyShapeStyle(.quaternary))
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(strokeColor, lineWidth: 1)
      }
  }

  private var strokeColor: Color {
    if isRecording { return theme.accent.opacity(0.6) }
    if isUnavailable { return .orange.opacity(0.5) }
    return .clear
  }

  /// Folds the state into the label rather than leaving it as unread decoration:
  /// a shortcut that will never fire has to be audible, not just orange.
  private var accessibilityLabel: String {
    if isRecording { return "Recording shortcut" }
    guard let binding else { return "Shortcut, not set" }
    if isUnavailable { return "Shortcut, \(binding.displayString), unavailable" }
    return "Shortcut, \(binding.displayString)"
  }
}

// MARK: - Key capture

private struct ShortcutCaptureView: NSViewRepresentable {
  @Binding var isRecording: Bool
  @Binding var liveModifiers: NSEvent.ModifierFlags
  let onChord: (HotkeyChord) -> Void
  let onClear: () -> Void
  /// Ends recording through the owner's single exit, so resuming Waves's own
  /// hot keys can never be skipped by a click-away.
  let onCancel: () -> Void

  func makeNSView(context: Context) -> CaptureView {
    let view = CaptureView()
    wire(view)
    return view
  }

  func updateNSView(_ view: CaptureView, context: Context) {
    wire(view)
    view.setRecording(isRecording)
  }

  private func wire(_ view: CaptureView) {
    view.onChord = onChord
    view.onClear = onClear
    view.onModifiers = { liveModifiers = $0 }
    view.onCancel = onCancel
  }

  final class CaptureView: NSView {
    var onChord: ((HotkeyChord) -> Void)?
    var onClear: (() -> Void)?
    var onModifiers: ((NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?

    private var isRecording = false

    override var acceptsFirstResponder: Bool { isRecording }

    func setRecording(_ recording: Bool) {
      guard recording != isRecording else { return }
      isRecording = recording
      if recording {
        window?.makeFirstResponder(self)
      } else if window?.firstResponder === self {
        window?.makeFirstResponder(nil)
      }
    }

    /// Menu equivalents arrive here and nowhere else. Claiming them while
    /// recording is what allows ⌘⌥Q to be recorded instead of quitting Waves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      guard isRecording else { return super.performKeyEquivalent(with: event) }
      handle(event)
      return true
    }

    override func keyDown(with event: NSEvent) {
      guard isRecording else {
        super.keyDown(with: event)
        return
      }
      handle(event)
    }

    override func flagsChanged(with event: NSEvent) {
      guard isRecording else {
        super.flagsChanged(with: event)
        return
      }
      onModifiers?(
        event.modifierFlags
          .intersection(.deviceIndependentFlagsMask)
          .subtracting([.capsLock, .function, .numericPad, .help])
      )
    }

    /// Clicking elsewhere ends recording, rather than leaving an invisible view
    /// silently eating the next keystroke.
    override func resignFirstResponder() -> Bool {
      if isRecording {
        isRecording = false
        onCancel?()
      }
      return super.resignFirstResponder()
    }

    private func handle(_ event: NSEvent) {
      // `.deviceIndependentFlagsMask` includes Caps Lock, Fn, numeric pad and
      // Help — none of which a chord can be built from. Left in, Caps Lock alone
      // would make Escape and Delete below look modified, killing both escape
      // hatches for anyone who happens to have it on.
      let flags = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.capsLock, .function, .numericPad, .help])

      // Escape alone cancels; Delete alone clears. Both remain recordable with a
      // modifier, so ⌘⌥⎋ is still a shortcut someone can bind.
      if flags.isEmpty {
        switch Int(event.keyCode) {
        case kVK_Escape:
          isRecording = false
          onCancel?()
          return
        case kVK_Delete, kVK_ForwardDelete:
          onClear?()
          return
        default:
          break
        }
      }

      onChord?(
        HotkeyChord(keyCode: event.keyCode, carbonModifiers: HotkeyModifiers.carbon(from: flags))
      )
    }
  }
}
