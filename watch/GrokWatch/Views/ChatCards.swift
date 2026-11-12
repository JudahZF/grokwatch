import SwiftUI

/// The shared frame for cards the Bot sends: a small header, then content. A card that waits for you has an orange dot.
private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    var isActive = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if isActive { Circle().fill(Theme.attention).frame(width: 6, height: 6) }
                Label(title, systemImage: systemImage)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            content
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 16))
    }
}

/// How a finished card reads, e.g. "✓ Approved".
private struct Outcome: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

struct QuestionCard: View {
    let message: ChatMessage
    let question: Question
    let model: ChatModel

    var body: some View {
        Card(title: "Question", systemImage: "questionmark.bubble", isActive: question.state == .open) {
            MarkdownText(question.prompt)
            if let help = question.help {
                Text(help).font(.caption2).foregroundStyle(.secondary)
            }
            switch question.state {
            case .open:
                if model.busyIDs.contains(message.id) {
                    ProgressView()
                } else {
                    ForEach(question.options, id: \.self) { option in
                        Button(option.label) { Task { await model.answer(message, with: option) } }
                            .buttonStyle(.pill)
                    }
                    Button("Skip") { Task { await model.skip(message) } }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            case .answered:
                Outcome(text: question.answerLabel ?? "Answered", systemImage: "checkmark")
            case .skipped:
                Outcome(text: "Skipped", systemImage: "arrow.uturn.forward")
            }
        }
    }
}

/// The three answers of the official apps. While it is open, the whole reason and command show,
/// so you never approve one you cannot read.
struct ApprovalCard: View {
    let message: ChatMessage
    let approval: Approval
    let model: ChatModel
    @State private var isConfirmingAlways = false

    var body: some View {
        Card(title: approval.isOpen ? "Needs approval" : "Approval", systemImage: "checkmark.shield", isActive: approval.isOpen) {
            Text(approval.summary).font(.footnote.weight(.medium))
            if let reason = approval.reason {
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(approval.isOpen ? nil : 2)
            }
            if approval.isOpen, let command = approval.command {
                Text(command).font(.caption2.monospaced())
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.45), in: .rect(cornerRadius: 8))
            }
            if approval.isOpen {
                if model.busyIDs.contains(message.id) {
                    ProgressView()
                } else {
                    Button("Allow once") { Task { await model.resolve(message, as: .approved) } }
                        .buttonStyle(.primaryPill)
                    Button("Always allow") { isConfirmingAlways = true }
                        .buttonStyle(.pill)
                    Button("Deny") { Task { await model.resolve(message, as: .denied) } }
                        .buttonStyle(.pill)
                }
            } else {
                Outcome(text: Self.label(for: approval.status), systemImage: Self.icon(for: approval.status))
            }
        }
        // "Always allow" saves a rule for the whole account, so it takes a second tap.
        .confirmationDialog("Always allow this?", isPresented: $isConfirmingAlways) {
            Button("Always allow") { Task { await model.resolve(message, as: .always) } }
        } message: {
            Text("The Bot will not ask again for actions like this.")
        }
    }

    private static func label(for status: String) -> String {
        status == "always" ? "Always allowed" : status.capitalized
    }

    private static func icon(for status: String) -> String {
        switch status {
        case "approved", "always": "checkmark"
        case "denied": "xmark"
        default: "clock"
        }
    }
}

struct DraftCard: View {
    let message: ChatMessage
    let draft: Draft
    let model: ChatModel
    @State private var isConfirming = false
    @State private var isShowingFull = false

    var body: some View {
        Card(title: draft.heading, systemImage: Self.icon(for: draft.payload), isActive: draft.isEditable) {
            if let subject = draft.subject, !subject.isEmpty {
                Text(subject).font(.footnote.weight(.semibold)).lineLimit(2)
            }
            Text(draft.body).font(.caption2).foregroundStyle(.secondary).lineLimit(5)
                .onTapGesture { isShowingFull = true }
            if draft.isEditable {
                if model.busyIDs.contains(message.id) {
                    ProgressView()
                } else {
                    HStack(spacing: 4) {
                        Button("Discard") { Task { await model.discardDraft(message) } }
                            .buttonStyle(.pill)
                        Button("Send") { isConfirming = true }
                            .buttonStyle(.primaryPill)
                    }
                }
            } else {
                Outcome(text: Self.label(for: draft.state), systemImage: draft.state == "sent" ? "paperplane" : "tray")
            }
        }
        // The card title names one recipient; the confirmation lists all of them, so you never send to someone you did not see.
        .confirmationDialog(draft.heading, isPresented: $isConfirming) {
            Button("Send") { Task { await model.sendDraft(message) } }
        } message: {
            Text(draft.addressLines.joined(separator: "\n"))
        }
        .sheet(isPresented: $isShowingFull) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(draft.heading).font(.footnote.weight(.semibold))
                    ForEach(draft.addressLines, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    if let subject = draft.subject { Text(subject).font(.footnote) }
                    Text(draft.body).font(.footnote)
                }
            }
        }
    }

    private static func icon(for payload: Aiserver_V1_SendGrokBotDraftRequest.OneOf_Draft) -> String {
        if case .slack = payload { "number" } else { "envelope" }
    }

    private static func label(for state: String) -> String {
        switch state {
        case "sent": "Sent"
        case "sending", "unconfirmed": "Sending…"
        case "discarded": "Discarded"
        default: state.capitalized
        }
    }
}

struct FormCard: View {
    let message: ChatMessage
    let form: UserForm
    let model: ChatModel
    @State private var isFilling = false

    var body: some View {
        Card(title: "Form", systemImage: "list.bullet.rectangle", isActive: form.isOpen) {
            Text(form.title).font(.footnote)
            if let instruction = form.instruction {
                Text(instruction).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
            }
            if form.isOpen {
                if model.busyIDs.contains(message.id) {
                    ProgressView()
                } else {
                    Button("Fill in") { isFilling = true }.buttonStyle(.primaryPill)
                }
            } else {
                Outcome(text: "Done", systemImage: "checkmark")
            }
        }
        .sheet(isPresented: $isFilling) {
            FormSheet(form: form) { values in
                Task { await model.submit(message, values: values) }
            } onDismiss: {
                Task { await model.dismissForm(message) }
            }
        }
    }
}

private struct FormSheet: View {
    @Environment(\.dismiss) private var dismiss
    let form: UserForm
    let onSubmit: ([String: String]) -> Void
    let onDismiss: () -> Void
    @State private var values: [String: String] = [:]

    var body: some View {
        List {
            ForEach(form.fields) { field in
                let binding = Binding { values[field.id, default: field.defaultValue] } set: { values[field.id] = $0 }
                if field.isSecret {
                    SecureField(field.label, text: binding)
                } else {
                    TextField(field.label, text: binding).textContentType(field.type == "email" ? .emailAddress : nil)
                }
            }
            Button("Submit") {
                onSubmit(filled)
                dismiss()
            }
            .disabled(form.fields.contains { $0.isRequired && filled[$0.id, default: ""].isEmpty })
            Button("Not now", role: .destructive) {
                onDismiss()
                dismiss()
            }
        }
        .navigationTitle(form.title)
    }

    private var filled: [String: String] {
        Dictionary(form.fields.map { ($0.id, values[$0.id, default: $0.defaultValue]) }) { first, _ in first }
    }
}

struct PhoneOnlyCard: View {
    let title: String
    let detail: String?
    let done: Bool

    var body: some View {
        Card(title: title, systemImage: done ? "checkmark.circle" : "iphone", isActive: false) {
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
            if !done { Text("Open Grok Bot on your phone.").font(.caption2) }
        }
    }
}
