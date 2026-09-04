import Foundation

enum AppIdentity {
    static let bundleIdentifier = "app.ihopeful.Ossuno"
    static let testBundleIdentifier = bundleIdentifier + ".tests"
    static let legacyBundleIdentifier = "studio.ossuno.oss"

    private static let defaultsMigrationKey = "appIdentity.didMigrateLegacyDefaults"
    private static let screenshotArguments = [
        "--ossuno-screenshot-browser",
        "--ossuno-screenshot-account"
    ]

    static func prepareForLaunch(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard shouldMigrateDefaults(arguments: arguments, environment: environment) else { return }
        let legacyDomain = defaults.persistentDomain(forName: legacyBundleIdentifier)
        migrateDefaults(from: legacyDomain, to: defaults)
    }

    static func shouldMigrateDefaults(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil else { return false }
        return !arguments.contains(where: screenshotArguments.contains)
    }

    static func migrateDefaults(
        from legacyDomain: [String: Any]?,
        to defaults: UserDefaults
    ) {
        guard !defaults.bool(forKey: defaultsMigrationKey) else { return }
        for (key, value) in legacyDomain ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: defaultsMigrationKey)
    }
}
