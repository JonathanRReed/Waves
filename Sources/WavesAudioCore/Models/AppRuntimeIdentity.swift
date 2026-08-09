import Foundation

/// Identifies one lifetime of a process. A PID by itself is not an identity
/// because the kernel may reuse it after termination.
public struct AppProcessLifetimeIdentity: Hashable, Sendable {
  public let pid: Int32
  public let startTimeSeconds: UInt64
  public let startTimeMicroseconds: UInt64

  public init(pid: Int32, startTimeSeconds: UInt64, startTimeMicroseconds: UInt64) {
    self.pid = pid
    self.startTimeSeconds = startTimeSeconds
    self.startTimeMicroseconds = startTimeMicroseconds
  }
}

/// Validated code-signing fields copied from Security.framework. The
/// designated requirement and code-directory hash bind the identity to signed
/// code instead of trusting mutable Info.plist metadata.
public struct AppCodeSigningIdentity: Hashable, Sendable {
  public let identifier: String
  public let teamIdentifier: String?
  public let designatedRequirement: String
  public let codeDirectoryHash: Data

  public init(
    identifier: String,
    teamIdentifier: String?,
    designatedRequirement: String,
    codeDirectoryHash: Data
  ) {
    self.identifier = identifier
    self.teamIdentifier = teamIdentifier
    self.designatedRequirement = designatedRequirement
    self.codeDirectoryHash = codeDirectoryHash
  }
}

/// Immutable identity captured from one running process outside the realtime
/// audio path. Paths are canonical, and the signing identity has already
/// passed Security.framework validity checks.
public struct AppRuntimeIdentity: Hashable, Sendable {
  public let lifetime: AppProcessLifetimeIdentity
  public let executablePath: String
  public let outerBundlePath: String
  public let signingIdentity: AppCodeSigningIdentity

  public init(
    lifetime: AppProcessLifetimeIdentity,
    executablePath: String,
    outerBundlePath: String,
    signingIdentity: AppCodeSigningIdentity
  ) {
    self.lifetime = lifetime
    self.executablePath = executablePath
    self.outerBundlePath = outerBundlePath
    self.signingIdentity = signingIdentity
  }
}
