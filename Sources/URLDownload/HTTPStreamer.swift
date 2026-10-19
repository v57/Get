import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Streams HTTP responses as they arrive: the response head, then each body
/// chunk, so a download writes data to disk as it comes instead of buffering
/// whole bodies (`URLSession.data`) or iterating byte by byte
/// (`URLSession.bytes`). One `URLSession` per streamer; `invalidate` it when
/// done, since the session retains its delegate.
final class HTTPStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Chunk: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
  }

  private let lock = NSLock()
  private var continuations: [Int: AsyncThrowingStream<Chunk, Error>.Continuation] = [:]
  private var session: URLSession!

  init(configuration: URLSessionConfiguration) {
    super.init()
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  /// Start `request`. Ending the iteration early (break, task cancellation)
  /// cancels the request.
  func stream(_ request: URLRequest) -> AsyncThrowingStream<Chunk, Error> {
    AsyncThrowingStream { continuation in
      let task = session.dataTask(with: request)
      lock.withLock { continuations[task.taskIdentifier] = continuation }
      continuation.onTermination = { _ in task.cancel() }
      task.resume()
    }
  }

  func invalidate() { session.invalidateAndCancel() }

  private func continuation(for task: URLSessionTask) -> AsyncThrowingStream<Chunk, Error>
    .Continuation?
  {
    lock.withLock { continuations[task.taskIdentifier] }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let http = response as? HTTPURLResponse {
      continuation(for: dataTask)?.yield(.response(http))
      completionHandler(.allow)
    } else {
      continuation(for: dataTask)?.finish(throwing: URLError(.badServerResponse))
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    continuation(for: dataTask)?.yield(.data(data))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let continuation = lock.withLock { continuations.removeValue(forKey: task.taskIdentifier) }
    if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
  }
}
