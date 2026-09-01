import WavesAudioCore

struct RouteHealthPresentation: Equatable, Sendable {
  enum Tone: Equatable, Sendable {
    case active
    case success
    case neutral
    case warning
    case error
  }

  let title: String
  let value: String
  let help: String
  let symbolName: String
  let tone: Tone

  var accessibilityLabel: String { "Route status: \(title)" }
  var accessibilityValue: String { value }

  init(app: AudioApp) {
    switch app.routeHealthContext {
    case .verifiedRouterOwnership:
      self.init(
        title: "Wave Link route",
        value: "Claimed by verified Wave Link",
        help: "Wave Link is routing this app. Waves is monitoring only; adjust the app in Wave Link.",
        symbolName: "arrow.triangle.branch",
        tone: .warning
      )
    case .unattributableRouterFallback:
      self.init(
        title: "Conservative handoff",
        value: "Wave Link is mixing this app",
        help: "Wave Link is mixing, and macOS cannot tell Waves which apps it captures. Waves is monitoring only so this app is never heard twice. Adjust it in Wave Link.",
        symbolName: "questionmark.diamond",
        tone: .warning
      )
    case .routerMixedOutput:
      self.init(
        title: "Wave Link mixed output",
        value: "Upstream mix left untouched",
        help: "Waves never wraps Wave Link's mixed output. Control upstream apps in Wave Link.",
        symbolName: "waveform.path.badge.minus",
        tone: .warning
      )
    case .waveLinkBridge:
      self.init(
        title: "Managed through Wave Link",
        value: "Volume and mute via Wave Link",
        help: app.notes ?? "Waves sends volume and mute to this app's Wave Link channel instead of adding a second audio route.",
        symbolName: "link.circle.fill",
        tone: .success
      )
    case .geometryRecoveryInProgress:
      self.init(
        title: "Recovering route",
        value: "Audio geometry changed",
        help: "Waves is rebuilding this route outside the realtime audio callback.",
        symbolName: "arrow.triangle.2.circlepath",
        tone: .warning
      )
    case .geometryRecoveryExhausted:
      self.init(
        title: "Recovery failed",
        value: "Geometry retry limit reached",
        help: app.notes ?? "Route recovery reached its retry limit. Use Recover Routes or restart Waves.",
        symbolName: "exclamationmark.octagon.fill",
        tone: .error
      )
    case nil:
      switch app.routingState {
      case .managed:
        self.init(
          title: "Managed",
          value: "Waves route active",
          help: "Waves is managing this app's audio route.",
          symbolName: "checkmark.circle.fill",
          tone: .success
        )
      case .live:
        self.init(
          title: "Live",
          value: "Audio detected",
          help: "Audio is playing and ready for per-app control.",
          symbolName: "waveform",
          tone: .active
        )
      case .monitorOnly:
        self.init(
          title: "Monitoring only",
          value: "Ready when you adjust a control",
          help: "Waves can see this app. Move its slider or mute it to start per-app control.",
          symbolName: "eye.circle",
          tone: .neutral
        )
      case .recent:
        self.init(
          title: "Recent",
          value: "Audio is currently quiet",
          help: "This app played audio recently.",
          symbolName: "clock.fill",
          tone: .neutral
        )
      case .error:
        self.init(
          title: "Route error",
          value: app.notes ?? "Route setup failed",
          help: app.notes ?? "Waves could not establish this app's route.",
          symbolName: "exclamationmark.triangle.fill",
          tone: .error
        )
      }
    }
  }

  private init(
    title: String,
    value: String,
    help: String,
    symbolName: String,
    tone: Tone
  ) {
    self.title = title
    self.value = value
    self.help = help
    self.symbolName = symbolName
    self.tone = tone
  }
}
