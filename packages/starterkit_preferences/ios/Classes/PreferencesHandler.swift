import Foundation

struct PreferencesFailure: Error, Equatable {
  let code: String
}

private final class CompletionOnce {
  private let lock = NSLock()
  private var completed = false
  private let completion: PreferencesHandler.Completion

  init(_ completion: @escaping PreferencesHandler.Completion) { self.completion = completion }

  func call(_ result: Result<Any?, PreferencesFailure>) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed = true
    lock.unlock()
    completion(result)
  }
}

/// Small Foundation-only operation handler shared by Flutter and native tests.
final class PreferencesHandler {
  typealias Completion = (Result<Any?, PreferencesFailure>) -> Void
  typealias Scheduler = (@escaping () -> Void) -> Void

  private let defaultsProvider: () -> UserDefaults
  private let schedule: Scheduler
  private(set) var isAttached = true
  private var generation: UInt64 = 0

  private static let prefix = "starterkit.preferences.v1."
  private static let sensitiveFragments = [
    "token", "access", "refresh", "password", "secret", "cookie", "auth", "apikey", "credential",
  ]

  init(defaultsProvider: @escaping () -> UserDefaults = { UserDefaults.standard },
       schedule: @escaping Scheduler) {
    self.defaultsProvider = defaultsProvider
    self.schedule = schedule
  }

  func detach() {
    isAttached = false
    generation &+= 1
  }

  func attach() {
    isAttached = true
    generation &+= 1
  }

  func handle(method: String, arguments: Any?, completion: @escaping Completion) {
    let complete = CompletionOnce(completion)
    let expected: Set<String>
    switch method {
    case "read", "remove": expected = ["key"]
    case "write": expected = ["key", "value"]
    default:
      complete.call(.failure(PreferencesFailure(code: "preference.invalid_arguments")))
      return
    }
    guard let args = arguments as? [String: Any], Set(args.keys) == expected else {
      complete.call(.failure(PreferencesFailure(code: "preference.invalid_arguments")))
      return
    }
    guard let key = Self.validatedKey(args["key"]) else {
      complete.call(.failure(PreferencesFailure(code: "preference.invalid_key")))
      return
    }
    let value = method == "write" ? Self.validatedValue(args["value"]) : nil
    if method == "write", value == nil {
      complete.call(.failure(PreferencesFailure(code: "preference.invalid_value")))
      return
    }
    guard isAttached else {
      complete.call(.failure(PreferencesFailure(code: "preference.unavailable")))
      return
    }
    let acceptedGeneration = generation
    schedule { [weak self] in
      guard let self, self.isAttached, self.generation == acceptedGeneration else {
        complete.call(.failure(PreferencesFailure(code: "preference.unavailable")))
        return
      }
      let defaults = self.defaultsProvider()
      let storageKey = Self.prefix + key
      switch method {
      case "read":
        let stored = defaults.object(forKey: storageKey)
        guard stored == nil || (stored is String && Self.validatedValue(stored) != nil) else {
          complete.call(.failure(PreferencesFailure(code: "preference.operation_failed")))
          return
        }
        complete.call(.success(stored))
      case "write":
        defaults.set(value, forKey: storageKey)
        complete.call(.success(nil))
      case "remove":
        defaults.removeObject(forKey: storageKey)
        complete.call(.success(nil))
      default:
        complete.call(.failure(PreferencesFailure(code: "preference.invalid_arguments")))
      }
    }
  }

  private static func validatedKey(_ candidate: Any?) -> String? {
    guard let key = candidate as? String, !key.isEmpty, key.utf8.count <= 128,
          key.utf8.allSatisfy({
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57)
              || $0 == 95 || $0 == 46 || $0 == 45
          }) else { return nil }
    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
    guard !sensitiveFragments.contains(where: normalized.contains) else { return nil }
    return key
  }

  private static func validatedValue(_ candidate: Any?) -> String? {
    guard let value = candidate as? String, !value.contains("\0"), value.utf8.count <= 4096 else { return nil }
    return value
  }
}
