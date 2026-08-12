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
    @Test
    func `Initialization rejects a null selection range`() {
        #expect(throws: (any Error).self) {
            try EditingContent(text: "meow", selectedRange: .null)
        }
    }

    @Test
    func `Initialization rejects a selection beyond the text`() {
        #expect(throws: (any Error).self) {
            try EditingContent(text: "meow", selectedRange: NSRange(location: 0, length: 5))
        }
    }

    // MARK: -

    @Test
    func `A null request leaves the content unchanged`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.null

        let updatedContent = try content.update(with: request)
        #expect(content == updatedContent)
    }

    @Test
    func `A text request replaces the text and preserves the selection`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.text("purr")

        let updatedContent = try content.update(with: request)
        #expect(updatedContent.text == "purr")
        #expect(updatedContent.selectedRange == .zero)
    }

    @Test
    func `A text request rejects a selection beyond the replacement text`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.text("purr", selectedRange: NSRange(location: 5, length: 0))

        #expect(throws: (any Error).self) {
            try content.update(with: request)
        }
    }

    @Test
    func `A subtext request rejects a replacement range beyond the text`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.subtext(range: NSRange(location: 5, length: 0), text: "purr")

        #expect(throws: (any Error).self) {
            try content.update(with: request)
        }
    }

    @Test
    func `A subtext request inserts text and advances the selection`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.subtext(range: .zero, text: "purr")

        let updatedContent = try content.update(with: request)
        #expect(updatedContent.text == "purrmeow")
        #expect(updatedContent.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test
    func `A subtext request rejects a selection beyond the updated text`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.subtext(range: .zero, text: "purr", selectedRange: NSRange(location: 9, length: 0))

        #expect(throws: (any Error).self) {
            try content.update(with: request)
        }
    }

    @Test
    func `A subtext request applies an explicit valid selection`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.subtext(range: .zero, text: "purr", selectedRange: NSRange(location: 8, length: 0))

        let updatedContent = try content.update(with: request)
        #expect(updatedContent.text == "purrmeow")
        #expect(updatedContent.selectedRange == NSRange(location: 8, length: 0))
    }

    @Test
    func `A text request applies an explicit valid selection`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.text("purr", selectedRange: NSRange(location: 4, length: 0))

        let updatedContent = try content.update(with: request)
        #expect(updatedContent.text == "purr")
        #expect(updatedContent.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test
    func `A selection request rejects a range beyond the text`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.selectedRange(NSRange(location: 5, length: 0))

        #expect(throws: (any Error).self) {
            try content.update(with: request)
        }
    }

    @Test
    func `A selection request updates only the selection`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let request = EditingContent.UpdateRequest.selectedRange(NSRange(location: 4, length: 0))

        let updatedContent = try content.update(with: request)
        #expect(updatedContent.text == "meow")
        #expect(updatedContent.selectedRange == NSRange(location: 4, length: 0))
    }

    // MARK: -

    @Test
    func `An unchanged value produces no change result`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let changedContent = content

        #expect(content.changeResult(from: changedContent) == nil)
    }

    @Test
    func `A text change is reported without a selection change`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let changedContent = try EditingContent(text: "purr", selectedRange: .zero)

        let changeResult = try #require(content.changeResult(from: changedContent))
        #expect(changeResult.isTextChanged)
        #expect(!changeResult.isSelectedRangeChanged)
    }

    @Test
    func `A selection change is reported without a text change`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let changedContent = try EditingContent(text: "meow", selectedRange: NSRange(location: 1, length: 0))

        let changeResult = try #require(content.changeResult(from: changedContent))
        #expect(!changeResult.isTextChanged)
        #expect(changeResult.isSelectedRangeChanged)
    }

    @Test
    func `Text and selection changes are both reported`() throws {
        let content = try EditingContent(text: "meow", selectedRange: .zero)
        let changedContent = try EditingContent(text: "purr", selectedRange: NSRange(location: 1, length: 0))

        let changeResult = try #require(content.changeResult(from: changedContent))
        #expect(changeResult.isTextChanged)
        #expect(changeResult.isSelectedRangeChanged)
    }
}
