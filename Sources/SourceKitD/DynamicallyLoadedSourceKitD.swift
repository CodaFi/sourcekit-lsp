//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LSPLogging
import SKSupport

import struct TSCBasic.AbsolutePath

/// Wrapper for sourcekitd, taking care of initialization, shutdown, and notification handler
/// multiplexing.
///
/// Users of this class should not call the api functions `initialize`, `shutdown`, or
/// `set_notification_handler`, which are global state managed internally by this class.
public final class DynamicallyLoadedSourceKitD: SourceKitD {

  /// The path to the sourcekitd dylib.
  public let path: AbsolutePath

  /// The handle to the dylib.
  let dylib: DLHandle

  /// The sourcekitd API functions.
  public let api: sourcekitd_api_functions_t

  /// Convenience for accessing known keys.
  public let keys: sourcekitd_api_keys

  /// Convenience for accessing known keys.
  public let requests: sourcekitd_api_requests

  /// Convenience for accessing known keys.
  public let values: sourcekitd_api_values

  /// Lock protecting private state.
  let lock: NSLock = NSLock()

  /// List of notification handlers that will be called for each notification.
  private var _notificationHandlers: [WeakSKDNotificationHandler] = []

  public static func getOrCreate(dylibPath: AbsolutePath) async throws -> SourceKitD {
    try await SourceKitDRegistry.shared
      .getOrAdd(dylibPath, create: { try DynamicallyLoadedSourceKitD(dylib: dylibPath) })
  }

  init(dylib path: AbsolutePath) throws {
    self.path = path
    #if os(Windows)
    self.dylib = try dlopen(path.pathString, mode: [])
    #else
    self.dylib = try dlopen(path.pathString, mode: [.lazy, .local, .first])
    #endif
    self.api = try sourcekitd_api_functions_t(self.dylib)
    self.keys = sourcekitd_api_keys(api: self.api)
    self.requests = sourcekitd_api_requests(api: self.api)
    self.values = sourcekitd_api_values(api: self.api)

    self.api.initialize()
    self.api.set_notification_handler { [weak self] rawResponse in
      guard let self, let rawResponse else { return }
      let handlers = self.lock.withLock { self._notificationHandlers.compactMap(\.value) }

      let response = SKDResponse(rawResponse, sourcekitd: self)
      for handler in handlers {
        handler.notification(response)
      }
    }
  }

  deinit {
    self.api.set_notification_handler(nil)
    self.api.shutdown()
    // FIXME: is it safe to dlclose() sourcekitd? If so, do that here. For now, let the handle leak.
    dylib.leak()
  }

  /// Adds a new notification handler (referenced weakly).
  public func addNotificationHandler(_ handler: SKDNotificationHandler) {
    lock.withLock {
      _notificationHandlers.removeAll(where: { $0.value == nil })
      _notificationHandlers.append(.init(handler))
    }
  }

  /// Removes a previously registered notification handler.
  public func removeNotificationHandler(_ handler: SKDNotificationHandler) {
    lock.withLock {
      _notificationHandlers.removeAll(where: { $0.value == nil || $0.value === handler })
    }
  }

  public func log(request: SKDRequestDictionary) {
    logger.info(
      """
      Sending sourcekitd request:
      \(request.forLogging)
      """
    )
  }

  public func log(response: SKDResponse) {
    logger.log(
      level: (response.error == nil || response.error == .requestCancelled) ? .debug : .error,
      """
      Received sourcekitd response:
      \(response.forLogging)
      """
    )
  }

  public func log(crashedRequest req: SKDRequestDictionary, fileContents: String?) {
    let log = """
      Request:
      \(req.description)

      File contents:
      \(fileContents ?? "<nil>")
      """
    let chunks = splitLongMultilineMessage(message: log)
    for (index, chunk) in chunks.enumerated() {
      logger.fault(
        """
        sourcekitd crashed (\(index + 1)/\(chunks.count))
        \(chunk)
        """
      )
    }
  }

}

struct WeakSKDNotificationHandler {
  weak private(set) var value: SKDNotificationHandler?
  init(_ value: SKDNotificationHandler) {
    self.value = value
  }
}
