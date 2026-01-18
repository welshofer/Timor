//
//  RateLimiterTests.swift
//  TimorTests
//
//  Tests for the RateLimiter actor that manages API rate limiting
//

import XCTest
@testable import Timor

final class RateLimiterTests: XCTestCase {

    // MARK: - Rate Limiting State Tests

    func testInitialStateNotRateLimited() async throws {
        let rateLimiter = RateLimiter()

        let isLimited = await rateLimiter.isRateLimited
        XCTAssertFalse(isLimited, "New rate limiter should not be rate limited")
    }

    func testRateLimitRemainingNilWhenNotLimited() async throws {
        let rateLimiter = RateLimiter()

        let remaining = await rateLimiter.rateLimitRemaining
        XCTAssertNil(remaining, "Rate limit remaining should be nil when not limited")
    }

    // MARK: - Rate Limit Handling Tests

    func testHandleRateLimitSetsRetryAfter() async throws {
        let rateLimiter = RateLimiter()

        await rateLimiter.handleRateLimit(retryAfterHeader: "5")

        let isLimited = await rateLimiter.isRateLimited
        XCTAssertTrue(isLimited, "Should be rate limited after handling 429")

        let remaining = await rateLimiter.rateLimitRemaining
        XCTAssertNotNil(remaining, "Should have remaining time")
        XCTAssertGreaterThan(remaining!, 0, "Remaining time should be positive")
    }

    func testHandleRateLimitParsesSeconds() async throws {
        let rateLimiter = RateLimiter()

        await rateLimiter.handleRateLimit(retryAfterHeader: "2")

        let remaining = await rateLimiter.rateLimitRemaining
        XCTAssertNotNil(remaining)
        // Should be approximately 2 seconds (allowing for execution time)
        XCTAssertLessThanOrEqual(remaining!, 3.0)
    }

    func testHandleRateLimitDefaultsToOneSecond() async throws {
        let rateLimiter = RateLimiter()

        await rateLimiter.handleRateLimit(retryAfterHeader: nil)

        let remaining = await rateLimiter.rateLimitRemaining
        XCTAssertNotNil(remaining)
        // Should default to ~1 second
        XCTAssertLessThanOrEqual(remaining!, 2.0)
    }

    // MARK: - Exponential Backoff Tests

    func testExponentialBackoffIncreasesWithFailures() async throws {
        let rateLimiter = RateLimiter()

        // First failure - 1x multiplier
        await rateLimiter.handleRateLimit(retryAfterHeader: "1")
        let firstRemaining = await rateLimiter.rateLimitRemaining ?? 0

        // Wait for rate limit to expire
        try await Task.sleep(nanoseconds: UInt64(firstRemaining * 1_000_000_000) + 100_000_000)

        // Second failure - 2x multiplier
        await rateLimiter.handleRateLimit(retryAfterHeader: "1")
        let secondRemaining = await rateLimiter.rateLimitRemaining ?? 0

        XCTAssertGreaterThan(secondRemaining, firstRemaining,
                            "Backoff should increase with consecutive failures")
    }

    // MARK: - Success Recording Tests

    func testRecordSuccessResetsFailureCount() async throws {
        let rateLimiter = RateLimiter()

        // Simulate some failures
        await rateLimiter.handleRateLimit(retryAfterHeader: "0.1")
        await rateLimiter.handleRateLimit(retryAfterHeader: "0.1")

        // Record success
        await rateLimiter.recordSuccess()

        // Next failure should use base multiplier (1x), not accumulated
        await rateLimiter.handleRateLimit(retryAfterHeader: "1")
        let remaining = await rateLimiter.rateLimitRemaining ?? 0

        // Should be close to 1 second (base), not 4+ seconds (accumulated)
        XCTAssertLessThan(remaining, 3.0,
                         "Success should reset backoff multiplier")
    }

    // MARK: - Wait If Needed Tests

    func testWaitIfNeededRespectsMinimumInterval() async throws {
        let rateLimiter = RateLimiter()

        // Make two rapid requests
        let start = Date()

        try await rateLimiter.waitIfNeeded()
        try await rateLimiter.waitIfNeeded()

        let elapsed = Date().timeIntervalSince(start)

        // Should have waited at least the minimum interval (100ms)
        XCTAssertGreaterThanOrEqual(elapsed, 0.09, // Allow small tolerance
                                    "Should wait minimum interval between requests")
    }

    // MARK: - Thread Safety Tests

    func testConcurrentAccessIsSafe() async throws {
        let rateLimiter = RateLimiter()

        // Spawn multiple concurrent tasks accessing the rate limiter
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await rateLimiter.isRateLimited
                    _ = await rateLimiter.rateLimitRemaining
                    await rateLimiter.recordSuccess()
                }
            }
        }

        // If we get here without crashing, thread safety is working
        XCTAssertTrue(true, "Concurrent access should not crash")
    }
}
