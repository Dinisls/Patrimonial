import Foundation

actor RateLimiter {
    private let maxTokens: Int
    private let refillInterval: TimeInterval
    private var tokens: Int
    private var lastRefill: Date
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxTokens: Int = 60, refillInterval: TimeInterval = 60) {
        self.maxTokens = maxTokens
        self.refillInterval = refillInterval
        self.tokens = maxTokens
        self.lastRefill = Date()
    }

    func acquire() async {
        refill()
        if tokens > 0 {
            tokens -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func tryAcquire() -> Bool {
        refill()
        if tokens > 0 {
            tokens -= 1
            return true
        }
        return false
    }

    var availableTokens: Int {
        tokens
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        if elapsed >= refillInterval {
            let periods = Int(elapsed / refillInterval)
            tokens = min(maxTokens, tokens + periods * maxTokens)
            lastRefill = now
            resumeWaiters()
        }
    }

    private func resumeWaiters() {
        while tokens > 0 && !waiters.isEmpty {
            tokens -= 1
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}
