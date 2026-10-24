import AppKit
import Foundation
import Testing
@testable import Uncloud

/// A flag the tests flip to say an export is running.
@MainActor
final class ExportFlag {
    var running = false
}

@MainActor
@Suite("AccountModel")
struct AccountModelTests {
    struct Harness {
        let model: AccountModel
        let service: PreviewAccountService
        let tokens: DefaultsAccountTokenStore
        let defaults: UserDefaults
        let clock: TestClock
        let export: ExportFlag
    }

    /// A preview model over an isolated suite. Pass the same `defaults` and `tokens` to simulate a relaunch.
    static func makeHarness(
        mode: AccountMode = .preview,
        defaults: UserDefaults? = nil,
        clock: TestClock = TestClock()
    ) -> Harness {
        let defaults = defaults ?? isolatedDefaults()
        let service = PreviewAccountService(store: PreviewAccountStore(defaults: defaults), now: clock.reader)
        let tokens = DefaultsAccountTokenStore(defaults: defaults)
        let export = ExportFlag()
        let model = AccountModel(
            mode: mode,
            service: service,
            tokens: tokens,
            defaults: defaults,
            clock: clock.reader,
            isExportRunning: { export.running }
        )
        return Harness(model: model, service: service, tokens: tokens, defaults: defaults, clock: clock, export: export)
    }

    /// Signs the model in with a preview email and the stub code.
    static func signIn(_ model: AccountModel, email: String = "name@example.com") async {
        await model.submitEmail(email, intent: .signUp)
        await model.submitCode(PreviewAccountService.code)
    }

    @Test("Sign Up runs email, code and lands signed in, with the tokens stored")
    func signUpFlow() async throws {
        let harness = Self.makeHarness()
        let model = harness.model
        model.show(.signUp)
        await model.submitEmail("name@example.com", intent: .signUp)
        guard case let .signedOut(.code(challenge, intent)) = model.phase else {
            Issue.record("Expected the code screen, got \(model.phase)")
            return
        }
        #expect(challenge.email == "name@example.com")
        #expect(intent == .signUp)

        await model.submitCode("123 456")
        #expect(model.phase == .signedIn)
        #expect(model.account?.email == "name@example.com")
        #expect(model.isNewAccount)
        #expect(harness.tokens.load() != nil)
    }

    @Test("Going back from the code screen keeps the email")
    func backKeepsEmail() async throws {
        let model = Self.makeHarness().model
        model.show(.signIn)
        await model.submitEmail("Name@Example.com", intent: .signIn)
        model.show(.signIn)
        #expect(model.phase == .signedOut(.signIn))
        #expect(model.email == "name@example.com")
    }

    @Test("An invalid email sets an error and sends nothing")
    func invalidEmail() async throws {
        let model = Self.makeHarness().model
        model.show(.signUp)
        await model.submitEmail("nope", intent: .signUp)
        #expect(model.error == .invalidEmail)
        #expect(model.phase == .signedOut(.signUp))
    }

    @Test("A wrong code keeps the code screen with an error")
    func wrongCode() async throws {
        let model = Self.makeHarness().model
        model.show(.signUp)
        await model.submitEmail("name@example.com", intent: .signUp)
        await model.submitCode("000000")
        #expect(model.error == .wrongCode)
        if case .signedOut(.code) = model.phase {} else { Issue.record("Expected to stay on the code screen") }
    }

    @Test("Cancelling a request leaves the screen as it was")
    func cancelLeavesRoute() async throws {
        let model = Self.makeHarness().model
        model.show(.signUp)
        let request = Task { await model.submitEmail("slow@example.com", intent: .signUp) }
        while !model.isBusy { await Task.yield() }
        model.cancelRequest()
        #expect(model.isBusy == false)
        #expect(model.phase == .signedOut(.signUp))
        await request.value
        #expect(model.phase == .signedOut(.signUp))
        #expect(model.isBusy == false)
    }

    @Test("Sign Out clears the account and tokens, and returns to Welcome")
    func signOutClears() async throws {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        await harness.model.signOut()
        #expect(harness.model.phase == .signedOut(.welcome))
        #expect(harness.model.account == nil)
        #expect(harness.tokens.load() == nil)
        #expect(harness.defaults.data(forKey: "uncloudAccount") == nil)
    }

    @Test("Sign Out is refused while an export runs")
    func signOutRefusedDuringExport() async throws {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        harness.export.running = true
        await harness.model.signOut()
        #expect(harness.model.phase == .signedIn)
        #expect(harness.tokens.load() != nil)
    }

    @Test("A revoked session during an export waits for the export to end")
    func revokedDuringExportDefers() async throws {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        let tokens = try #require(harness.tokens.load())
        await harness.service.signOut(tokens: tokens)

        harness.export.running = true
        await harness.model.refreshAccount(force: true)
        #expect(harness.model.phase == .signedIn)
        #expect(harness.model.showsAppMenus)

        // Still running: the hook that runs at the end of a run must not end the session early.
        harness.model.exportDidFinish()
        #expect(harness.model.phase == .signedIn)

        harness.export.running = false
        harness.model.exportDidFinish()
        #expect(harness.model.phase == .signedOut(.welcome))
        #expect(harness.model.error == .signedOut)
        #expect(!harness.model.showsAppMenus)
    }

    @Test("A revoked session outside an export signs out at once")
    func revokedSignsOut() async throws {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        let tokens = try #require(harness.tokens.load())
        await harness.service.signOut(tokens: tokens)
        await harness.model.refreshAccount(force: true)
        #expect(harness.model.phase == .signedOut(.welcome))
        #expect(harness.model.error == .signedOut)
    }

    @Test("Signed in state survives a relaunch, and the account check is kept")
    func relaunch() async throws {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        let relaunched = Self.makeHarness(defaults: harness.defaults, clock: harness.clock).model
        #expect(relaunched.phase == .signedIn)
        #expect(relaunched.account?.email == "name@example.com")
    }

    @Test("A signed-in account has every feature: the menus and the summary are open to it")
    func signedInHasEverything() async throws {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        #expect(harness.model.showsAppMenus)
        #expect(harness.model.summary.hasAccount)
        #expect(harness.model.summary.state == .signedIn)
        #expect(harness.model.summary.accessibilityValue == "name@example.com")
    }

    @Test("A plan cache from an earlier build is removed at launch")
    func legacyPlanCacheRemoved() async throws {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        harness.defaults.set(Data("{}".utf8), forKey: "uncloudEntitlement")
        _ = Self.makeHarness(defaults: harness.defaults, clock: harness.clock)
        #expect(harness.defaults.data(forKey: "uncloudEntitlement") == nil)
    }

    @Test("Mode off has no account flow")
    func modeOff() async throws {
        let harness = Self.makeHarness(mode: .off)
        #expect(harness.model.phase == .off)
        #expect(harness.model.summary.state == .hidden)
        await harness.model.submitEmail("name@example.com", intent: .signUp)
        #expect(harness.model.phase == .off)
    }

    @Test("Build configuration: preview only in Debug; live only with every live value, all https")
    func configurationResolves() {
        func resolve(_ mode: String?, debug: Bool, base: String?, complete: Bool = true) -> AccountMode {
            AccountConfiguration.resolve(
                mode: mode,
                isDebug: debug,
                baseURL: base,
                supabaseURL: complete ? "https://supa.example.co" : nil,
                supabasePublishableKey: complete ? "sb_publishable_test" : nil
            ).mode
        }
        #expect(resolve("preview", debug: true, base: nil) == .preview)
        #expect(resolve("preview", debug: false, base: nil) == .off)
        #expect(resolve("off", debug: true, base: nil) == .off)
        #expect(resolve(nil, debug: true, base: nil) == .off)
        #expect(resolve("live", debug: false, base: "https://api.example.com") == .live)
        #expect(resolve("live", debug: false, base: "https://api.example.com", complete: false) == .off)
        #expect(resolve("live", debug: false, base: "http://api.example.com") == .off)
        #expect(resolve("live", debug: false, base: "") == .off)
        #expect(resolve("live", debug: false, base: nil) == .off)
    }

    @Test("Delete Account forgets the account on this Mac and tells the signed-out screens")
    func deleteAccountHappyPath() async {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        let deleted = await harness.model.deleteAccount(confirmEmail: "  Name@Example.com ")
        #expect(deleted)
        #expect(harness.model.phase == .signedOut(.welcome))
        #expect(harness.model.account == nil)
        #expect(harness.model.notice == .accountDeleted)
        #expect(harness.model.error == nil)
        #expect(harness.model.isDeletingAccount == false)
        #expect(harness.tokens.load() == nil)
        #expect(harness.defaults.data(forKey: "uncloudAccount") == nil)
        #expect(PreviewAccountStore(defaults: harness.defaults).load()["name@example.com"] == nil)
    }

    @Test("A confirmation that doesn't match is refused locally, and nothing is deleted")
    func deleteAccountMismatch() async {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        #expect(await harness.model.deleteAccount(confirmEmail: "other@example.com") == false)
        #expect(harness.model.error == .confirmationMismatch)
        #expect(harness.model.phase == .signedIn)
        #expect(PreviewAccountStore(defaults: harness.defaults).load()["name@example.com"] != nil)
    }

    @Test("Delete Account is refused during an export")
    func deleteAccountDuringExport() async {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        harness.export.running = true
        #expect(await harness.model.deleteAccount(confirmEmail: "name@example.com") == false)
        #expect(harness.model.phase == .signedIn)
    }

    @Test("A second delete while one is running is ignored")
    func deleteAccountOnce() async {
        let harness = Self.makeHarness()
        let model = harness.model
        await Self.signIn(model, email: "slow@example.com")
        async let first = model.deleteAccount(confirmEmail: "slow@example.com")
        while !model.isDeletingAccount {
            await Task.yield()
        }
        #expect(await model.deleteAccount(confirmEmail: "slow@example.com") == false)
        #expect(await first)
        #expect(model.phase == .signedOut(.welcome))
    }

    @Test("The deleted notice clears on the next sign-in")
    func noticeClearsOnSignIn() async {
        let harness = Self.makeHarness()
        await Self.signIn(harness.model)
        await harness.model.deleteAccount(confirmEmail: "name@example.com")
        #expect(harness.model.notice == .accountDeleted)
        harness.clock.advance(by: 60)
        await Self.signIn(harness.model)
        #expect(harness.model.notice == nil)
    }

    @Test("The sign-out confirmation flag round trips")
    func signOutFlag() async {
        let harness = Self.makeHarness()
        #expect(harness.model.isConfirmingSignOut == false)
        harness.model.isConfirmingSignOut = true
        #expect(harness.model.isConfirmingSignOut)
        harness.model.isConfirmingSignOut = false
        #expect(harness.model.isConfirmingSignOut == false)
    }
}
