//
//  Sequence.swift
//  TwitterTextEditor
//
//  Copyright 2021 Twitter, Inc.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
@testable import TwitterTextEditor
import Testing

private final class Locked<Value>: @unchecked Sendable {
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

struct SequenceTest {
    @Test("For each continues through the sequence")
    func forEachContinuesThroughSequence() async {
        let sequence = [1, 2, 3]
        let queue = DispatchQueue(label: #function)
        let results = Locked([Int]())
        let completed = Locked(false)

        sequence.forEach(queue: queue, completion: {
            completed.withValue { $0 = true }
        }, { element, next in
            results.withValue { $0.append(element) }
            next(.continue)
        })

        #expect(await waitUntil { completed.value })
        #expect(results.value == sequence)
    }

    @Test("For each breaks after the first element")
    func forEachBreaksAfterFirstElement() async {
        let sequence = [1, 2, 3]
        let queue = DispatchQueue(label: #function)
        let results = Locked([Int]())
        let completed = Locked(false)

        sequence.forEach(queue: queue, completion: {
            completed.withValue { $0 = true }
        }, { element, next in
            results.withValue { $0.append(element) }
            next(.break)
        })

        #expect(await waitUntil { completed.value })
        #expect(results.value == [1])
    }

    @Test("For each works without a completion closure")
    func forEachWorksWithoutCompletion() async {
        let sequence = [1, 2, 3]
        let queue = DispatchQueue(label: #function)
        let results = Locked([Int]())
        let completed = Locked(false)

        sequence.forEach(queue: queue) { element, next in
            let count = results.withValue { values in
                values.append(element)
                return values.count
            }
            if count < sequence.count {
                next(.continue)
            } else {
                completed.withValue { $0 = true }
            }
        }

        #expect(await waitUntil { completed.value })
        #expect(results.value == sequence)
    }

    @Test("For each supports an asynchronous body")
    func forEachSupportsAsynchronousBody() async {
        let sequence = [1, 2, 3]
        let queue = DispatchQueue(label: #function)
        let results = Locked([Int]())
        let completed = Locked(false)

        sequence.forEach(queue: queue, completion: {
            completed.withValue { $0 = true }
        }, { element, next in
            DispatchQueue.global().async {
                results.withValue { $0.append(element) }
                next(.continue)
            }
        })

        #expect(await waitUntil { completed.value })
        #expect(results.value == sequence)
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
