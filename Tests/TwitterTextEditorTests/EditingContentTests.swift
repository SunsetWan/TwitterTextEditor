//
//  EditingContentTests.swift
//  TwitterTextEditor
//
//  Copyright 2021 Twitter, Inc.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
@testable import TwitterTextEditor
import Testing

@Suite
struct EditingContentTests {
    @Test("Initialization rejects a null selection range")
    func initializationRejectsNullSelectionRange() {
        #expect(throws: (any Error).self) {
            try EditingContent(text: "meow", selectedRange: .null)
        }
    }

    @Test("Initialization rejects a selection beyond the text")
    func initializationRejectsSelectionBeyondText() {
        #expect(throws: (any Error).self) {
            try EditingContent(text: "meow", selectedRange: NSRange(location: 0, length: 5))
        }
    }

    // MARK: -

    @Test("A null request leaves the content unchanged")
    func nullRequestLeavesContentUnchanged() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.null

        let updatedContent = try content.update(with: request)
        #expect(content == updatedContent)
    }

    @Test("A text request replaces the text and preserves the selection")
    func textRequestReplacesTextAndPreservesSelection() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.text("purr")

        let updatedContent = try content.update(with: request)
        #expect(updatedContent.text == "purr")
        #expect(updatedContent.selectedRange == .zero)
    }

    @Test("A text request rejects a selection beyond the replacement text")
    func textRequestRejectsSelectionBeyondReplacementText() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.text("purr", selectedRange: NSRange(location: 5, length: 0))

        #expect(throws: (any Error).self) {
            try content.update(with: request)
        }
    }

    @Test("A subtext request rejects a replacement range beyond the text")
    func subtextRequestRejectsReplacementRangeBeyondText() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.subtext(range: NSRange(location: 5, length: 0), text: "purr")

        #expect(throws: (any Error).self) {
            try content.update(with: request)
        }
    }

    @Test("A subtext request inserts text and advances the selection")
    func subtextRequestInsertsTextAndAdvancesSelection() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.subtext(range: .zero, text: "purr")

        let updatedContent = try content.update(with: request)
        #expect(updatedContent.text == "purrmeow")
        #expect(updatedContent.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test("A subtext request rejects a selection beyond the updated text")
    func subtextRequestRejectsSelectionBeyondUpdatedText() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.subtext(range: .zero, text: "purr", selectedRange: NSRange(location: 9, length: 0))

        #expect(throws: (any Error).self) {
            try content.update(with: request)
        }
    }

    @Test("A subtext request applies an explicit valid selection")
    func subtextRequestAppliesExplicitValidSelection() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.subtext(range: .zero, text: "purr", selectedRange: NSRange(location: 8, length: 0))

        let updatedContent = try content.update(with: request)
        #expect(updatedContent.text == "purrmeow")
        #expect(updatedContent.selectedRange == NSRange(location: 8, length: 0))
    }

    @Test("A text request applies an explicit valid selection")
    func textRequestAppliesExplicitValidSelection() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.text("purr", selectedRange: NSRange(location: 4, length: 0))

        let updatedContent = try content.update(with: request)
        #expect(updatedContent.text == "purr")
        #expect(updatedContent.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test("A selection request rejects a range beyond the text")
    func selectionRequestRejectsRangeBeyondText() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.selectedRange(NSRange(location: 5, length: 0))

        #expect(throws: (any Error).self) {
            try content.update(with: request)
        }
    }

    @Test("A selection request updates only the selection")
    func selectionRequestUpdatesOnlySelection() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.selectedRange(NSRange(location: 4, length: 0))

        let updatedContent = try content.update(with: request)
        #expect(updatedContent.text == "meow")
        #expect(updatedContent.selectedRange == NSRange(location: 4, length: 0))
    }

    // MARK: -

    @Test("An unchanged value produces no change result")
    func unchangedValueProducesNoChangeResult() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let changedContent = content

        #expect(content.changeResult(from: changedContent) == nil)
    }

    @Test("A text change is reported without a selection change")
    func textChangeIsReportedWithoutSelectionChange() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let changedContent = try EditingContent(text: "purr", selectedRange: .zero)

        let changeResult = try #require(content.changeResult(from: changedContent))
        #expect(changeResult.isTextChanged)
        #expect(!changeResult.isSelectedRangeChanged)
    }

    @Test("A selection change is reported without a text change")
    func selectionChangeIsReportedWithoutTextChange() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let changedContent = try EditingContent(text: "meow", selectedRange: NSRange(location: 1, length: 0))

        let changeResult = try #require(content.changeResult(from: changedContent))
        #expect(!changeResult.isTextChanged)
        #expect(changeResult.isSelectedRangeChanged)
    }

    @Test("Text and selection changes are both reported")
    func textAndSelectionChangesAreBothReported() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let changedContent = try EditingContent(text: "purr", selectedRange: NSRange(location: 1, length: 0))

        let changeResult = try #require(content.changeResult(from: changedContent))
        #expect(changeResult.isTextChanged)
        #expect(changeResult.isSelectedRangeChanged)
    }
}
