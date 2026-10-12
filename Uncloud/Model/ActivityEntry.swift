import Foundation

struct ActivityEntry: Identifiable, Sendable {
    enum Kind: Sendable {
        case info, success, warning, error
    }

    let id = UUID()
    let date = Date()
    let kind: Kind
    let message: String
}
