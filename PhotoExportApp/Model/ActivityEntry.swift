import Foundation

struct ActivityEntry: Identifiable {
    enum Kind {
        case info, success, warning, error
    }

    let id = UUID()
    let date = Date()
    let kind: Kind
    let message: String
}
