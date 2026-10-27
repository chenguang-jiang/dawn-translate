import Foundation

struct EmailInputs: Equatable {
    let context: String
    let intent: String
    let tone: String
}

struct EmailDraft {
    private(set) var context = ""
    private(set) var intent = ""
    private(set) var tone = "简洁专业"
    private(set) var contextTranslation = ""
    private(set) var reply = ""
    private(set) var replyTranslation = ""
    private var replyInputs: EmailInputs?

    var contextDirection: TranslationDirection { TranslationDirection.detect(context) }
    // Replies follow the incoming message, regardless of the intent's language.
    var replyDirection: TranslationDirection { contextDirection == .toEnglish ? .toChinese : .toEnglish }
    var inputs: EmailInputs { EmailInputs(context: context, intent: intent, tone: tone) }
    var canGenerate: Bool { !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var replyIsStale: Bool { !reply.isEmpty && replyInputs != inputs }
    var canCopyReply: Bool { !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !replyIsStale }

    mutating func updateContext(_ value: String) {
        guard value != context else { return }
        context = value
        contextTranslation = ""
    }
    mutating func updateIntent(_ value: String) { intent = value }
    mutating func updateTone(_ value: String) { tone = value }

    mutating func editReply(_ value: String) {
        guard value != reply else { return }
        reply = value
        replyTranslation = ""
        replyInputs = inputs
    }

    @discardableResult
    mutating func applyContextTranslation(_ value: String, for original: String) -> Bool {
        guard original == context else { return false }
        contextTranslation = value
        return true
    }

    @discardableResult
    mutating func applyReply(_ value: String, for original: EmailInputs) -> Bool {
        guard original == inputs else { return false }
        reply = value
        replyTranslation = ""
        replyInputs = original
        return true
    }

    @discardableResult
    mutating func applyReplyTranslation(_ value: String, reply originalReply: String, inputs originalInputs: EmailInputs) -> Bool {
        guard originalReply == reply, originalInputs == inputs, !replyIsStale else { return false }
        replyTranslation = value
        return true
    }
}
