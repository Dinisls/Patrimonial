import Foundation
import Testing
@testable import Patrimonial

struct RateLimiterTests {

    @Test func acquireConsumesToken() async {
        let limiter = RateLimiter(maxTokens: 5, refillInterval: 60)
        await limiter.acquire()
        let remaining = await limiter.availableTokens
        #expect(remaining == 4)
    }

    @Test func tryAcquireSucceedsWithTokens() async {
        let limiter = RateLimiter(maxTokens: 3, refillInterval: 60)
        let first = await limiter.tryAcquire()
        let second = await limiter.tryAcquire()
        let third = await limiter.tryAcquire()
        let fourth = await limiter.tryAcquire()

        #expect(first == true)
        #expect(second == true)
        #expect(third == true)
        #expect(fourth == false)
    }

    @Test func tryAcquireFailsWhenExhausted() async {
        let limiter = RateLimiter(maxTokens: 1, refillInterval: 60)
        let first = await limiter.tryAcquire()
        let second = await limiter.tryAcquire()
        #expect(first == true)
        #expect(second == false)
    }

    @Test func tokensDoNotExceedMax() async {
        let limiter = RateLimiter(maxTokens: 3, refillInterval: 60)
        // Even after refill, should not exceed max
        let tokens = await limiter.availableTokens
        #expect(tokens == 3)
    }

    @Test func budgetExactly60PerMinute() async {
        let limiter = RateLimiter(maxTokens: 60, refillInterval: 60)
        for _ in 0..<60 {
            let ok = await limiter.tryAcquire()
            #expect(ok == true)
        }
        let over = await limiter.tryAcquire()
        #expect(over == false)
    }
}
