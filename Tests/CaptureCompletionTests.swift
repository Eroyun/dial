import Foundation

@main enum CaptureCompletionTests {
    static func main() async throws {
        let cancelled = CaptureCompletion<Int>()
        cancelled.resolve(.failure(CancellationError()))
        do {
            let _: Int = try await withCheckedThrowingContinuation { cancelled.install($0) }
            preconditionFailure("Cancellation before callback setup must win")
        } catch is CancellationError {}
        cancelled.resolve(.success(99)) // An OS callback can arrive after cancellation.

        for _ in 0..<200 {
            let completion = CaptureCompletion<Int>()
            let value = try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                DispatchQueue.concurrentPerform(iterations: 16) { candidate in completion.resolve(.success(candidate)) }
            }
            precondition((0..<16).contains(value))
            completion.resolve(.failure(CancellationError()))
        }
        print("Capture completion: cancellation-before-setup and 3200 competing callbacks passed")
    }
}
