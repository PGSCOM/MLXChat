import Foundation
import SwiftData

/// A document attached as project knowledge. Stored as a plain `Codable`
/// blob on `Project` rather than its own `@Model` — the knowledge is capped
/// at `Project.knowledgeCharacterLimit` characters total, so it's a few KB
/// at most.
/// ponytail: if project knowledge ever needs to scale past that, split this
/// into a real `@Model` with a `.cascade` relationship to `Project`.
struct ProjectDocument: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var fileName: String
    var text: String
    var wasTruncated: Bool

    init(id: UUID = UUID(), fileName: String, text: String, wasTruncated: Bool) {
        self.id = id
        self.fileName = fileName
        self.text = text
        self.wasTruncated = wasTruncated
    }
}

/// Groups conversations that share context — like claude.ai's projects.
/// `instructions` and `documents` are folded into every member
/// conversation's system prompt once per turn (see
/// `Conversation.effectiveSystemPrompt`), so the same background doesn't
/// have to be re-pasted or re-attached in each new chat.
@Model
final class Project {
    var id: UUID
    var name: String
    var instructions: String
    var createdAt: Date
    var documents: [ProjectDocument] = []

    @Relationship(deleteRule: .nullify, inverse: \Conversation.project)
    var conversations: [Conversation] = []

    init(name: String, instructions: String = "") {
        id = UUID()
        self.name = name
        self.instructions = instructions
        createdAt = .now
    }

    /// Total characters across all documents — the real context budget
    /// depends on whatever model ends up loaded, which isn't known here, so
    /// this is a conservative, model-independent ceiling.
    static let knowledgeCharacterLimit = 24_000

    var knowledgeCharacterCount: Int {
        documents.reduce(0) { $0 + $1.text.count }
    }

    /// Instructions plus documents, folded into one block and capped at
    /// `knowledgeCharacterLimit`. Empty when the project has neither.
    var contextBlock: String {
        var parts: [String] = []
        if !instructions.isEmpty { parts.append(instructions) }

        var remaining = Project.knowledgeCharacterLimit - instructions.count
        var wasTruncated = false
        for document in documents {
            guard remaining > 0 else { wasTruncated = true; break }
            let piece = "Documento del proyecto: \(document.fileName)\n\n\(document.text)"
            if piece.count > remaining {
                parts.append(String(piece.prefix(remaining)))
                wasTruncated = true
                remaining = 0
            } else {
                parts.append(piece)
                remaining -= piece.count
            }
        }

        guard !parts.isEmpty else { return "" }
        var block = parts.joined(separator: "\n\n---\n\n")
        if wasTruncated {
            block += "\n\n[el conocimiento del proyecto se truncó por longitud]"
        }
        return block
    }
}
