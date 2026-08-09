import SwiftUI

@MainActor
enum PreferenceBinding {
  static func durable<Value>(
    store: AppStore,
    _ keyPath: WritableKeyPath<UserPreferences, Value>
  ) -> Binding<Value> {
    make(
      get: { store.preferences[keyPath: keyPath] },
      set: { store.preferences[keyPath: keyPath] = $0 },
      persist: { store.persistPreferences() }
    )
  }

  static func make<Value>(
    get: @escaping () -> Value,
    set: @escaping (Value) -> Void,
    persist: @escaping () -> Void
  ) -> Binding<Value> {
    Binding(
      get: { get() },
      set: { value in
        set(value)
        persist()
      }
    )
  }
}
