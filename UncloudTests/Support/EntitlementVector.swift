import Foundation
@testable import Uncloud

/// The shared signature vector (`Fixtures/entitlement-vector.json`): a test key pair, a message and its signature.
/// The same file is the server's fixture, so both sides sign and verify the same bytes (plan §4.5).
struct EntitlementVector: Decodable {
    let publicKey: String
    let accountId: String
    let plan: String
    let status: String
    let currentPeriodEnd: String
    let cancelAtPeriodEnd: Bool
    let checkedAt: String
    let message: String
    let signature: String

    static func load() -> EntitlementVector {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/entitlement-vector.json")
        do {
            return try JSONDecoder().decode(EntitlementVector.self, from: Data(contentsOf: url))
        } catch {
            fatalError("entitlement-vector.json is missing or malformed: \(error)")
        }
    }

    /// The vector as an entitlement, with its signature.
    var entitlement: Entitlement {
        Entitlement(
            plan: Plan(rawValue: plan) ?? .free,
            status: Entitlement.Status(rawValue: status) ?? .none,
            currentPeriodEnd: WireDate.parse(currentPeriodEnd),
            cancelAtPeriodEnd: cancelAtPeriodEnd,
            checkedAt: WireDate.parse(checkedAt) ?? .distantPast,
            signature: signature
        )
    }
}
