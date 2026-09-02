enum OssunoMCPVersion {
    /// Canonical ossuno-mcp release version. The npm publish script reads this
    /// value and synchronizes every package manifest before publishing.
    static let current = "1.0.3"

    static var banner: String { "ossuno-mcp \(current)" }
}
