import AppKit
import Foundation

struct AccessibilityAnnouncementPoster: Sendable {
  typealias Post = @MainActor @Sendable (AttributedString) -> Void

  private let postImplementation: Post

  init(post: @escaping Post) {
    postImplementation = post
  }

  @MainActor
  func post(_ announcement: AttributedString) {
    postImplementation(announcement)
  }

  static let live = AccessibilityAnnouncementPoster { announcement in
    AccessibilityNotification.Announcement(announcement).post()
  }
}
