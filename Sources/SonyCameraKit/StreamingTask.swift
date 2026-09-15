import Foundation

/// Wraps a URLSession data task so an endless HTTP body arrives as chunks in an AsyncStream.
final class StreamingTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    func start(url: URL) -> AsyncThrowingStream<Data, Error> {
        let stream = AsyncThrowingStream<Data, Error> { cont in
            self.continuation = cont
            cont.onTermination = { [weak self] _ in self?.cancel() }
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = .infinity
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let t = s.dataTask(with: req)
        task = t
        t.resume()
        return stream
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil; session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        continuation = nil
    }
}
