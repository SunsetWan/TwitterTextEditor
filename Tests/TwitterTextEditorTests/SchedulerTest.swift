//
//  SchedulerTest.swift
//  TwitterTextEditor
//
//  Copyright 2021 Twitter, Inc.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
@testable import TwitterTextEditor
import Testing

private protocol Runner {
    func perform(_: @escaping @Sendable () -> Void)
}

extension RunLoop: Runner {
}

extension DispatchQueue: Runner {
    func perform(_ block: @escaping @Sendable () -> Void) {
        async(execute: block)
    }
}

private extension Collection {
    subscript(optional index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Result {
    var success: Success? {
        switch self {
        case .success(let value):
            return value
        default:
            return nil
        }
    }

    var failure: Failure? {
        switch self {
        case .failure(let value):
            return value
        default:
            return nil
        }
    }
}

private final class SchedulerTestState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var value: Value {
        withValue { $0 }
    }
}

@Suite(.serialized)
@MainActor
struct SchedulerTest {
    private func wait(for runner: Runner) async -> Bool {
        let completed = SchedulerTestState(false)
        runner.perform {
            completed.withValue { $0 = true }
        }
        return await waitUntil { completed.value }
    }

    // MARK: -

    @Test("Debounce scheduler performs a scheduled block once")
    func debouncePerformsScheduledBlockOnce() async {
        var performedCount = 0
        let scheduler = DebounceScheduler {
            performedCount += 1
        }

        scheduler.schedule()
        scheduler.schedule()

        #expect(performedCount == 0)

        #expect(await wait(for: RunLoop.main))

        #expect(performedCount == 1)
    }

    @Test("Debounce scheduler performs immediately")
    func debouncePerformsImmediately() async {
        var performedCount = 0
        let scheduler = DebounceScheduler {
            performedCount += 1
        }

        scheduler.schedule()
        scheduler.perform()

        #expect(performedCount == 1)

        #expect(await wait(for: RunLoop.main))

        #expect(performedCount == 1)
    }

    @Test("Debounce scheduler schedules again after performing")
    func debounceSchedulesAgainAfterPerforming() async {
        var performedCount = 0
        let scheduler = DebounceScheduler {
            performedCount += 1
        }

        scheduler.schedule()
        scheduler.perform()
        scheduler.schedule()

        #expect(performedCount == 1)

        #expect(await wait(for: RunLoop.main))

        #expect(performedCount == 2)
    }

    // MARK: -

    @Test("Content filter scheduler performs only the latest schedule")
    func contentFilterPerformsOnlyLatestSchedule() async {
        var performedCount = 0
        let scheduler = ContentFilterScheduler<String, String> { input, completion in
            performedCount += 1
            completion(.success(input))
        }

        var results = [Result<String, Error>]()
        let completion = { (result: Result<String, Error>) in
            results.append(result)
        }

        scheduler.schedule("meow", completion: completion)
        scheduler.schedule("purr", completion: completion)

        #expect(performedCount == 0)
        #expect(results.count == 1)
        #expect(results[optional: 0]?.failure as? SchedulerError == .cancelled)

        #expect(await wait(for: RunLoop.main))

        #expect(performedCount == 1)
        #expect(results.count == 2)
        #expect(results[optional: 1]?.success == "purr")
    }

    @Test("Content filter scheduler uses its cache")
    func contentFilterUsesCache() async {
        var performedCount = 0
        let scheduler = ContentFilterScheduler<String, String> { input, completion in
            performedCount += 1
            completion(.success(input))
        }

        var results = [Result<String, Error>]()
        let completion = { (result: Result<String, Error>) in
            results.append(result)
        }

        scheduler.schedule("meow", completion: completion)

        #expect(await wait(for: RunLoop.main))

        #expect(performedCount == 1)
        #expect(results.count == 1)
        #expect(results[optional: 0]?.success == "meow")

        scheduler.schedule("meow", completion: completion)

        #expect(await wait(for: RunLoop.main))

        #expect(performedCount == 1)
        #expect(results.count == 2)
        #expect(results[optional: 1]?.success == "meow")
    }

    @Test("Content filter scheduler cancels pending work before using its cache")
    func contentFilterCancelsPendingWorkBeforeCache() async {
        var performedCount = 0
        let scheduler = ContentFilterScheduler<String, String> { input, completion in
            performedCount += 1
            completion(.success(input))
        }

        var results = [Result<String, Error>]()
        let completion = { (result: Result<String, Error>) in
            results.append(result)
        }

        scheduler.schedule("meow", completion: completion)

        #expect(await wait(for: RunLoop.main))

        #expect(performedCount == 1)
        #expect(results.count == 1)
        #expect(results[optional: 0]?.success == "meow")

        // This schedule should be cancelled.
        scheduler.schedule("purr", completion: completion)
        // This schedule should use cache.
        scheduler.schedule("meow", completion: completion)

        #expect(performedCount == 1)
        #expect(results.count == 2)
        #expect(results[optional: 1]?.failure as? SchedulerError == .cancelled)

        #expect(await wait(for: RunLoop.main))

        #expect(performedCount == 1)
        #expect(results.count == 3)
        #expect(results[optional: 2]?.success == "meow")
    }

    @Test("Content filter scheduler rejects an obsolete result")
    func contentFilterRejectsObsoleteResult() async {
        var performedCount = 0
        var pendingResults = [(input: String, completion: (Result<String, Error>) -> Void)]()

        let scheduler = ContentFilterScheduler<String, String> { input, completion in
            performedCount += 1
            pendingResults.append((input, completion))
        }

        var results = [Result<String, Error>]()
        let completion = { (result: Result<String, Error>) in
            results.append(result)
        }

        #expect(performedCount == 0)

        scheduler.schedule("meow", completion: completion)

        #expect(await wait(for: RunLoop.main))

        #expect(performedCount == 1)
        #expect(pendingResults.count == 1)

        scheduler.schedule("purr", completion: completion)
        #expect(await wait(for: RunLoop.main))

        #expect(performedCount == 2)
        #expect(pendingResults.count == 2)

        // Complete the older request only after the newer request has installed its token.
        // This makes the stale-result ordering explicit instead of depending on the relative
        // scheduling behavior of RunLoop and DispatchQueue.
        pendingResults[0].completion(.success(pendingResults[0].input))
        pendingResults[1].completion(.success(pendingResults[1].input))

        #expect(performedCount == 2)
        #expect(results.count == 2)
        #expect(results[optional: 0]?.failure as? SchedulerError == .notLatest)
        #expect(results[optional: 1]?.success == "purr")
    }

    @Test("Content filter scheduler cache hit invalidates an older in flight result")
    func cacheHitInvalidatesOlderInFlightResult() async {
        var filteredInputs = [String]()
        var pendingFirstCompletion: ((Result<String, Error>) -> Void)?
        let scheduler = ContentFilterScheduler<String, String> { input, completion in
            filteredInputs.append(input)
            if input == "first" {
                pendingFirstCompletion = completion
            } else {
                completion(.success("cached-second"))
            }
        }

        var primingResult: Result<String, Error>?
        scheduler.schedule("second") { result in
            primingResult = result
        }
        #expect(await wait(for: RunLoop.main))
        #expect(primingResult?.success == "cached-second")

        var firstResult: Result<String, Error>?
        scheduler.schedule("first") { result in
            firstResult = result
        }
        #expect(await wait(for: RunLoop.main))
        #expect(pendingFirstCompletion != nil)

        var cachedSecondResult: Result<String, Error>?
        scheduler.schedule("second") { result in
            cachedSecondResult = result
        }
        #expect(await wait(for: RunLoop.main))
        #expect(cachedSecondResult?.success == "cached-second")

        pendingFirstCompletion?(.success("obsolete-first"))
        #expect(firstResult?.failure as? SchedulerError == .notLatest)

        // A final request proves the obsolete result did not replace the cached value.
        var retainedCacheResult: Result<String, Error>?
        scheduler.schedule("second") { result in
            retainedCacheResult = result
        }
        #expect(await wait(for: RunLoop.main))
        #expect(retainedCacheResult?.success == "cached-second")
        #expect(filteredInputs == ["second", "first"])
    }

    @Test("Content filter scheduler delivers a background result on the main thread")
    func contentFilterDeliversBackgroundResultOnMainThread() async {
        let delivery = SchedulerTestState<(isMainThread: Bool, value: String?)?>(nil)
        let scheduler = ContentFilterScheduler<String, String> { input, completion in
            DispatchQueue.global().async {
                completion(.success(input))
            }
        }

        scheduler.schedule("meow") { result in
            delivery.withValue { value in
                value = (Thread.isMainThread, try? result.get())
            }
        }

        #expect(await waitUntil { delivery.value != nil })
        #expect(delivery.value?.isMainThread == true)
        #expect(delivery.value?.value == "meow")
    }
}

private func waitUntil(
    timeout: Duration = .seconds(3),
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
