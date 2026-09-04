import Foundation
import Testing
@testable import Ossuno

struct AppIdentityTests {
    @Test func identifiersUseTheRequestedDomain() {
        #expect(AppIdentity.bundleIdentifier == "app.ihopeful.Ossuno")
        #expect(AppIdentity.testBundleIdentifier == "app.ihopeful.Ossuno.tests")
        #expect(AppIdentity.legacyBundleIdentifier == "studio.ossuno.oss")
    }

    @Test func migrationCopiesOnlyMissingDefaultsAndRunsOnce() {
        let suiteName = "Ossuno.AppIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("current", forKey: "shared")
        AppIdentity.migrateDefaults(
            from: [
                "legacyOnly": "copied",
                "shared": "legacy"
            ],
            to: defaults
        )

        #expect(defaults.string(forKey: "legacyOnly") == "copied")
        #expect(defaults.string(forKey: "shared") == "current")

        AppIdentity.migrateDefaults(
            from: ["afterMigration": "must-not-copy"],
            to: defaults
        )
        #expect(defaults.string(forKey: "afterMigration") == nil)
    }

    @Test func testsAndScreenshotProcessesSkipMigration() {
        #expect(!AppIdentity.shouldMigrateDefaults(
            arguments: ["Ossuno"],
            environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"]
        ))
        #expect(!AppIdentity.shouldMigrateDefaults(
            arguments: ["Ossuno", "--ossuno-screenshot-browser"],
            environment: [:]
        ))
        #expect(!AppIdentity.shouldMigrateDefaults(
            arguments: ["Ossuno", "--ossuno-screenshot-account"],
            environment: [:]
        ))
        #expect(AppIdentity.shouldMigrateDefaults(arguments: ["Ossuno"], environment: [:]))
    }
}
