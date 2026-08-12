//
//  NSRangeTests.swift
//  TwitterTextEditor
//
//  Copyright 2021 Twitter, Inc.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
@testable import TwitterTextEditor
import Testing

@Suite
struct NSRangeTests {
    struct MovementCase: CustomTestStringConvertible, Sendable {
        let range: NSRange
        let replacedRange: NSRange
        let replacementLength: Int
        let expectedRange: NSRange
        let testDescription: String

        init(
            _ testDescription: String,
            rangeLocation: Int,
            rangeLength: Int,
            replacedLocation: Int,
            replacedLength: Int,
            replacementLength: Int,
            expectedLocation: Int,
            expectedLength: Int
        ) {
            self.range = NSRange(location: rangeLocation, length: rangeLength)
            self.replacedRange = NSRange(location: replacedLocation, length: replacedLength)
            self.replacementLength = replacementLength
            self.expectedRange = NSRange(location: expectedLocation, length: expectedLength)
            self.testDescription = testDescription
        }
    }

    @Test(arguments: rangeWithLengthCases)
    func `A nonempty range moves when text is replaced`(_ testCase: MovementCase) {
        let movedRange = testCase.range.movedByReplacing(
            range: testCase.replacedRange,
            length: testCase.replacementLength
        )

        #expect(movedRange == testCase.expectedRange)
    }

    @Test(arguments: emptyRangeCases)
    func `An empty range moves when text is replaced`(_ testCase: MovementCase) {
        let movedRange = testCase.range.movedByReplacing(
            range: testCase.replacedRange,
            length: testCase.replacementLength
        )

        #expect(movedRange == testCase.expectedRange)
    }

    // These cases exercise every boundary relationship between a nonempty range
    // and the range being replaced, including zero-length insertion points.
    static let rangeWithLengthCases: [MovementCase] = [
        .init("replacement below lower bound shrinks", rangeLocation: 2, rangeLength: 3, replacedLocation: 0, replacedLength: 1, replacementLength: 0, expectedLocation: 1, expectedLength: 3),
        .init("replacement below lower bound is equal length", rangeLocation: 2, rangeLength: 3, replacedLocation: 0, replacedLength: 1, replacementLength: 1, expectedLocation: 2, expectedLength: 3),
        .init("replacement below lower bound grows", rangeLocation: 2, rangeLength: 3, replacedLocation: 0, replacedLength: 1, replacementLength: 2, expectedLocation: 3, expectedLength: 3),
        .init("insertion below lower bound inserts nothing", rangeLocation: 2, rangeLength: 3, replacedLocation: 1, replacedLength: 0, replacementLength: 0, expectedLocation: 2, expectedLength: 3),
        .init("insertion below lower bound inserts one", rangeLocation: 2, rangeLength: 3, replacedLocation: 1, replacedLength: 0, replacementLength: 1, expectedLocation: 3, expectedLength: 3),
        .init("replacement ending at lower bound shrinks", rangeLocation: 2, rangeLength: 3, replacedLocation: 1, replacedLength: 1, replacementLength: 0, expectedLocation: 1, expectedLength: 3),
        .init("replacement ending at lower bound is equal length", rangeLocation: 2, rangeLength: 3, replacedLocation: 1, replacedLength: 1, replacementLength: 1, expectedLocation: 2, expectedLength: 3),
        .init("replacement ending at lower bound grows", rangeLocation: 2, rangeLength: 3, replacedLocation: 1, replacedLength: 1, replacementLength: 2, expectedLocation: 3, expectedLength: 3),
        .init("insertion at lower bound inserts nothing", rangeLocation: 2, rangeLength: 3, replacedLocation: 2, replacedLength: 0, replacementLength: 0, expectedLocation: 2, expectedLength: 3),
        .init("insertion at lower bound inserts one", rangeLocation: 2, rangeLength: 3, replacedLocation: 2, replacedLength: 0, replacementLength: 1, expectedLocation: 3, expectedLength: 3),
        .init("replacement crossing lower bound shrinks", rangeLocation: 2, rangeLength: 3, replacedLocation: 1, replacedLength: 2, replacementLength: 1, expectedLocation: 1, expectedLength: 3),
        .init("replacement crossing lower bound is equal length", rangeLocation: 2, rangeLength: 3, replacedLocation: 1, replacedLength: 2, replacementLength: 2, expectedLocation: 1, expectedLength: 4),
        .init("replacement crossing lower bound grows", rangeLocation: 2, rangeLength: 3, replacedLocation: 1, replacedLength: 2, replacementLength: 3, expectedLocation: 1, expectedLength: 5),
        .init("replacement at lower bound deletes one", rangeLocation: 2, rangeLength: 3, replacedLocation: 2, replacedLength: 1, replacementLength: 0, expectedLocation: 2, expectedLength: 2),
        .init("replacement at lower bound is equal length", rangeLocation: 2, rangeLength: 3, replacedLocation: 2, replacedLength: 1, replacementLength: 1, expectedLocation: 2, expectedLength: 3),
        .init("replacement at lower bound grows", rangeLocation: 2, rangeLength: 3, replacedLocation: 2, replacedLength: 1, replacementLength: 2, expectedLocation: 2, expectedLength: 4),
        .init("insertion inside near lower bound inserts nothing", rangeLocation: 2, rangeLength: 3, replacedLocation: 3, replacedLength: 0, replacementLength: 0, expectedLocation: 2, expectedLength: 3),
        .init("insertion inside near lower bound inserts one", rangeLocation: 2, rangeLength: 3, replacedLocation: 3, replacedLength: 0, replacementLength: 1, expectedLocation: 2, expectedLength: 4),
        .init("replacement inside deletes one", rangeLocation: 2, rangeLength: 3, replacedLocation: 3, replacedLength: 1, replacementLength: 0, expectedLocation: 2, expectedLength: 2),
        .init("replacement inside is equal length", rangeLocation: 2, rangeLength: 3, replacedLocation: 3, replacedLength: 1, replacementLength: 1, expectedLocation: 2, expectedLength: 3),
        .init("replacement inside grows", rangeLocation: 2, rangeLength: 3, replacedLocation: 3, replacedLength: 1, replacementLength: 2, expectedLocation: 2, expectedLength: 4),
        .init("insertion inside near upper bound inserts nothing", rangeLocation: 2, rangeLength: 3, replacedLocation: 4, replacedLength: 0, replacementLength: 0, expectedLocation: 2, expectedLength: 3),
        .init("insertion inside near upper bound inserts one", rangeLocation: 2, rangeLength: 3, replacedLocation: 4, replacedLength: 0, replacementLength: 1, expectedLocation: 2, expectedLength: 4),
        .init("replacement at upper interior deletes one", rangeLocation: 2, rangeLength: 3, replacedLocation: 4, replacedLength: 1, replacementLength: 0, expectedLocation: 2, expectedLength: 2),
        .init("replacement at upper interior is equal length", rangeLocation: 2, rangeLength: 3, replacedLocation: 4, replacedLength: 1, replacementLength: 1, expectedLocation: 2, expectedLength: 3),
        .init("replacement at upper interior grows", rangeLocation: 2, rangeLength: 3, replacedLocation: 4, replacedLength: 1, replacementLength: 2, expectedLocation: 2, expectedLength: 4),
        .init("replacement crossing upper bound shrinks", rangeLocation: 2, rangeLength: 3, replacedLocation: 4, replacedLength: 2, replacementLength: 1, expectedLocation: 2, expectedLength: 3),
        .init("replacement crossing upper bound is equal length", rangeLocation: 2, rangeLength: 3, replacedLocation: 4, replacedLength: 2, replacementLength: 2, expectedLocation: 2, expectedLength: 4),
        .init("replacement crossing upper bound grows", rangeLocation: 2, rangeLength: 3, replacedLocation: 4, replacedLength: 2, replacementLength: 3, expectedLocation: 2, expectedLength: 5),
        .init("insertion at upper bound inserts nothing", rangeLocation: 2, rangeLength: 3, replacedLocation: 5, replacedLength: 0, replacementLength: 0, expectedLocation: 2, expectedLength: 3),
        .init("insertion at upper bound inserts one", rangeLocation: 2, rangeLength: 3, replacedLocation: 5, replacedLength: 0, replacementLength: 1, expectedLocation: 2, expectedLength: 3),
        .init("replacement starting at upper bound deletes one", rangeLocation: 2, rangeLength: 3, replacedLocation: 5, replacedLength: 1, replacementLength: 0, expectedLocation: 2, expectedLength: 3),
        .init("replacement starting at upper bound is equal length", rangeLocation: 2, rangeLength: 3, replacedLocation: 5, replacedLength: 1, replacementLength: 1, expectedLocation: 2, expectedLength: 3),
        .init("replacement starting at upper bound grows", rangeLocation: 2, rangeLength: 3, replacedLocation: 5, replacedLength: 1, replacementLength: 2, expectedLocation: 2, expectedLength: 3),
        .init("insertion above upper bound inserts nothing", rangeLocation: 2, rangeLength: 3, replacedLocation: 6, replacedLength: 0, replacementLength: 0, expectedLocation: 2, expectedLength: 3),
        .init("insertion above upper bound inserts one", rangeLocation: 2, rangeLength: 3, replacedLocation: 6, replacedLength: 0, replacementLength: 1, expectedLocation: 2, expectedLength: 3),
        .init("insertion above upper bound inserts two", rangeLocation: 2, rangeLength: 3, replacedLocation: 6, replacedLength: 0, replacementLength: 2, expectedLocation: 2, expectedLength: 3),
        .init("nonempty scenario above upper bound deletes one", rangeLocation: 2, rangeLength: 3, replacedLocation: 6, replacedLength: 1, replacementLength: 0, expectedLocation: 2, expectedLength: 3),
        .init("nonempty scenario above upper bound is equal length", rangeLocation: 2, rangeLength: 3, replacedLocation: 6, replacedLength: 1, replacementLength: 1, expectedLocation: 2, expectedLength: 3),
        .init("nonempty scenario above upper bound grows", rangeLocation: 2, rangeLength: 3, replacedLocation: 6, replacedLength: 1, replacementLength: 2, expectedLocation: 2, expectedLength: 3)
    ]

    // These cases pin the affinity rules used when a caret lies before, on,
    // inside, or after the replacement range.
    static let emptyRangeCases: [MovementCase] = [
        .init("caret before replacement after deletion", rangeLocation: 0, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 0, expectedLocation: 0, expectedLength: 0),
        .init("caret before equal-length replacement", rangeLocation: 0, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 4, expectedLocation: 0, expectedLength: 0),
        .init("caret before growing replacement", rangeLocation: 0, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 8, expectedLocation: 0, expectedLength: 0),
        .init("caret on lower bound after deletion", rangeLocation: 1, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 0, expectedLocation: 1, expectedLength: 0),
        .init("caret on lower bound after equal-length replacement", rangeLocation: 1, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 4, expectedLocation: 1, expectedLength: 0),
        .init("caret on lower bound after growing replacement", rangeLocation: 1, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 8, expectedLocation: 1, expectedLength: 0),
        .init("caret below midpoint after deletion", rangeLocation: 2, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 0, expectedLocation: 1, expectedLength: 0),
        .init("caret below midpoint after equal-length replacement", rangeLocation: 2, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 4, expectedLocation: 1, expectedLength: 0),
        .init("caret below midpoint after growing replacement", rangeLocation: 2, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 8, expectedLocation: 1, expectedLength: 0),
        .init("caret at midpoint after deletion", rangeLocation: 3, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 0, expectedLocation: 1, expectedLength: 0),
        .init("caret at midpoint after equal-length replacement", rangeLocation: 3, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 4, expectedLocation: 5, expectedLength: 0),
        .init("caret at midpoint after growing replacement", rangeLocation: 3, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 8, expectedLocation: 9, expectedLength: 0),
        .init("caret above midpoint after deletion", rangeLocation: 4, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 0, expectedLocation: 1, expectedLength: 0),
        .init("caret above midpoint after equal-length replacement", rangeLocation: 4, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 4, expectedLocation: 5, expectedLength: 0),
        .init("caret above midpoint after growing replacement", rangeLocation: 4, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 8, expectedLocation: 9, expectedLength: 0),
        .init("caret on upper bound after deletion", rangeLocation: 5, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 0, expectedLocation: 1, expectedLength: 0),
        .init("caret on upper bound after equal-length replacement", rangeLocation: 5, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 4, expectedLocation: 5, expectedLength: 0),
        .init("caret on upper bound after growing replacement", rangeLocation: 5, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 8, expectedLocation: 9, expectedLength: 0),
        .init("caret after replacement after deletion", rangeLocation: 6, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 0, expectedLocation: 2, expectedLength: 0),
        .init("caret after equal-length replacement", rangeLocation: 6, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 4, expectedLocation: 6, expectedLength: 0),
        .init("caret after growing replacement", rangeLocation: 6, rangeLength: 0, replacedLocation: 1, replacedLength: 4, replacementLength: 8, expectedLocation: 10, expectedLength: 0)
    ]
}
