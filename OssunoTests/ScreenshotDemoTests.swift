#if DEBUG
import Foundation
import Testing
@testable import Ossuno

@MainActor
struct ScreenshotDemoTests {
    @Test func browserFixtureUsesSyntheticIsolatedWorkspace() {
        let model = ScreenshotDemo.makeModel(for: .browser)

        #expect(model.accounts.count == 1)
        #expect(model.selectedAccount?.name == "Ossuno 演示工作室")
        #expect(model.selectedAccount?.accessKeyId == "LTAI5tDEMO0000000000")
        #expect(model.selectedBucketName == "ossuno-studio-assets")
        #expect(model.browser.prefix == "campaigns/2026-autumn/")
        #expect(model.browser.viewMode == .list)
        #expect(model.browser.folders.count == 4)
        #expect(model.browser.objects.count == 7)
        #expect(model.browser.selectedKeys == ["campaigns/2026-autumn/发布素材/"])
        #expect(model.favorites.items.map(\.name) == ["品牌素材", "待发布"])
        #expect(model.searchScope == .folder)
        #expect(model.searchController.results.isEmpty)
        #expect(model.transfers.jobs.count == 2)
        #expect(!model.showAccountSheet)
    }

    @Test func accountFixtureIsClearlyNonProduction() {
        let model = ScreenshotDemo.makeModel(for: .account)
        let draft = ScreenshotDemo.accountDraft

        #expect(model.showAccountSheet)
        #expect(draft.name == "Ossuno 演示工作室")
        #expect(draft.accessKeyId.contains("DEMO"))
        #expect(draft.secret == "demo-secret-never-used")
        #expect(draft.defaultACL == .default)
        #expect(draft.defaultACL.title == "继承存储空间")
        #expect(draft.prefixTemplate == "assets/{yyyy}/{MM}/{dd}/")
    }

    @Test func accountErrorFixtureRequiresAnExplicitDebugArgument() {
        #expect(ScreenshotDemo.accountFailure(arguments: []) == nil)
        #expect(ScreenshotDemo.accountFailure(
            arguments: ["Ossuno", "--ossuno-screenshot-account-error"]
        ) == nil)

        let failure = ScreenshotDemo.accountFailure(
            arguments: [
                "Ossuno",
                "--ossuno-screenshot-account",
                "--ossuno-screenshot-account-error"
            ]
        )

        #expect(failure?.operation == .savingAccount)
        #expect(failure?.isKeychainFailure == true)
        #expect(failure?.message.contains("错误码 -25308") == true)
    }

    @Test func accountAdvancedFixtureRequiresAnExplicitDebugArgument() {
        #expect(!ScreenshotDemo.accountShowsAdvanced(arguments: ["Ossuno", "--ossuno-screenshot-account"]))
        #expect(
            ScreenshotDemo.accountShowsAdvanced(
                arguments: [
                    "Ossuno",
                    "--ossuno-screenshot-account",
                    "--ossuno-screenshot-account-advanced"
                ]
            )
        )
    }

    @Test func screenshotOutputURLRequiresAnExplicitPath() {
        #expect(ScreenshotDemo.outputURL(arguments: ["Ossuno", "--ossuno-screenshot-browser"]) == nil)
        #expect(
            ScreenshotDemo.outputURL(
                arguments: [
                    "Ossuno",
                    "--ossuno-screenshot-output=/tmp/ossuno-browser.png"
                ]
            ) == URL(fileURLWithPath: "/tmp/ossuno-browser.png")
        )
    }
}
#endif
