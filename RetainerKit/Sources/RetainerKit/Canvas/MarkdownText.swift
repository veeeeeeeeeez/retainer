import Foundation
import SwiftUI

/// One block of a rendered note.
struct MarkdownBlock: Identifiable, Equatable {

    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        /// A list item or a further paragraph inside one. `marker` is the
        /// bullet or number, or `nil` for a continuation paragraph.
        case listItem(marker: String?, depth: Int)
        case code
        case quote
        case rule
    }

    let id: Int
    var kind: Kind
    var text: AttributedString
}

/// Splits Markdown into blocks using Foundation's parser.
///
/// SwiftUI's `Text` renders inline Markdown (emphasis, code, links) but drops
/// block structure, so paragraphs and lists are laid out here: the parser
/// tags every run with the block it belongs to, and runs sharing a tag become
/// one block.
enum MarkdownParser {

    static func blocks(from source: String) -> [MarkdownBlock] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: trimmed, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(trimmed))]
        }

        var blocks: [MarkdownBlock] = []
        var currentIntent: PresentationIntent?
        var hasCurrent = false
        var lastListItemIdentity: Int?

        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if piece.link != nil {
                // Links stay monochrome; the underline marks them.
                piece.underlineStyle = .single
            }
            if hasCurrent, run.presentationIntent == currentIntent, !blocks.isEmpty {
                blocks[blocks.count - 1].text.append(piece)
                continue
            }
            currentIntent = run.presentationIntent
            hasCurrent = true
            let kind = kind(for: run.presentationIntent, lastListItemIdentity: &lastListItemIdentity)
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind, text: piece))
        }

        // Code blocks carry their trailing newline; drop it.
        for index in blocks.indices where blocks[index].kind == .code {
            let characters = blocks[index].text.characters
            if characters.last == "\n" {
                blocks[index].text.removeSubrange(characters.index(before: characters.endIndex)..<characters.endIndex)
            }
        }
        return blocks
    }

    /// Classifies a block from its intent, whose components run from the
    /// innermost (the paragraph) outwards (the lists containing it).
    private static func kind(for intent: PresentationIntent?, lastListItemIdentity: inout Int?) -> MarkdownBlock.Kind {
        guard let components = intent?.components else {
            lastListItemIdentity = nil
            return .paragraph
        }

        var listDepth = 0
        var itemOrdinal: Int?
        var itemIdentity: Int?
        var itemIsOrdered = false
        var sawItem = false
        var result: MarkdownBlock.Kind?

        for component in components {
            switch component.kind {
            case .header(let level):
                result = result ?? .heading(level: level)
            case .codeBlock:
                result = result ?? .code
            case .blockQuote:
                result = result ?? .quote
            case .thematicBreak:
                result = result ?? .rule
            case .listItem(let ordinal):
                if !sawItem {
                    itemOrdinal = ordinal
                    itemIdentity = component.identity
                }
            case .orderedList:
                if itemOrdinal != nil && !sawItem {
                    itemIsOrdered = true
                    sawItem = true
                }
                listDepth += 1
            case .unorderedList:
                if itemOrdinal != nil && !sawItem { sawItem = true }
                listDepth += 1
            default:
                break
            }
        }

        if let itemOrdinal, let itemIdentity, result == nil || result == .code {
            defer { lastListItemIdentity = itemIdentity }
            if result == .code { return .code }
            let depth = max(0, listDepth - 1)
            if lastListItemIdentity == itemIdentity {
                return .listItem(marker: nil, depth: depth)
            }
            return .listItem(marker: itemIsOrdered ? "\(itemOrdinal)." : "–", depth: depth)
        }

        lastListItemIdentity = nil
        return result ?? .paragraph
    }
}

/// Parsed notes, kept so a node does not re-parse on every frame of a zoom.
@MainActor
private enum MarkdownCache {
    private static var storage: [String: [MarkdownBlock]] = [:]

    static func blocks(for source: String) -> [MarkdownBlock] {
        if let cached = storage[source] { return cached }
        let parsed = MarkdownParser.blocks(from: source)
        if storage.count > 400 { storage.removeAll(keepingCapacity: true) }
        storage[source] = parsed
        return parsed
    }
}

/// A note rendered as Markdown in the reading typeface.
struct MarkdownText: View {

    let source: String
    var fontSize: CGFloat = 16

    var body: some View {
        let blocks = MarkdownCache.blocks(for: source)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                view(for: block)
                    .padding(.top, spacing(before: block, in: blocks))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Theme.text)
    }

    /// Paragraphs sit most of a line apart; items of one list sit closer.
    private func spacing(before block: MarkdownBlock, in blocks: [MarkdownBlock]) -> CGFloat {
        guard block.id > 0 else { return 0 }
        if case .listItem = block.kind, case .listItem = blocks[block.id - 1].kind {
            return (fontSize * 0.3).rounded()
        }
        return (fontSize * 0.75).rounded()
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            body(block.text)
        case .heading(let level):
            Text(block.text)
                .font(Theme.noteFont(size: fontSize * (level <= 1 ? 1.25 : 1.1)).weight(.semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.45) {
                Text(marker ?? "")
                    .font(Theme.noteFont(size: fontSize))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
                    .frame(width: fontSize * 1.15, alignment: .trailing)
                body(block.text)
            }
            .padding(.leading, CGFloat(depth) * fontSize * 1.2)
        case .code:
            Text(block.text)
                .font(Theme.mono(fontSize * 0.82))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(fontSize * 0.2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(fontSize * 0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        case .quote:
            HStack(alignment: .top, spacing: fontSize * 0.7) {
                Rectangle()
                    .fill(Theme.hairlineStrong)
                    .frame(width: 2)
                body(block.text, color: Theme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: Theme.hairlineWidth)
        }
    }

    private func body(_ text: AttributedString, color: Color = Theme.text) -> some View {
        Text(text)
            .font(Theme.noteFont(size: fontSize))
            .lineSpacing(Theme.noteLineSpacing(size: fontSize))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
