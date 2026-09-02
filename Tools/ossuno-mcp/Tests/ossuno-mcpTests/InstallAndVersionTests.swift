import XCTest
@testable import ossuno_mcp

final class InstallAndVersionTests: XCTestCase, @unchecked Sendable {
    func testAllSupportedClientsIncludesClaudeCode() {
        XCTAssertTrue(InstallCommand.supportedClientIDs.contains("claude-code"))
        XCTAssertTrue(InstallCommand.supportedClientIDs.contains("trae"))
        XCTAssertEqual(Set(InstallCommand.supportedClientIDs).count, InstallCommand.supportedClientIDs.count)
    }

    func testVersionHasSingleRuntimeSource() {
        XCTAssertEqual(OssunoMCPVersion.banner, "ossuno-mcp \(OssunoMCPVersion.current)")
        XCTAssertFalse(OssunoMCPVersion.current.isEmpty)
    }

    func testJSONReinstallPreservesExistingEnv() throws {
        let root: [String: Any] = [
            "mcpServers": [
                "ossuno": [
                    "command": "npx",
                    "args": ["-y", "ossuno-mcp"],
                    "env": [
                        "OSSUNO_MCP_ALLOWED_ROOTS": "/Users/me/projects",
                        "OSSUNO_MCP_DEFAULT_BUCKET": "prod",
                    ],
                ]
            ]
        ]
        let json = try InstallCommand.encodedJSONForTesting(
            root: root,
            launch: .npx,
            uninstalling: false
        )
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let servers = try XCTUnwrap(parsed["mcpServers"] as? [String: Any])
        let ossuno = try XCTUnwrap(servers["ossuno"] as? [String: Any])
        let env = try XCTUnwrap(ossuno["env"] as? [String: Any])
        XCTAssertEqual(env["OSSUNO_MCP_ALLOWED_ROOTS"] as? String, "/Users/me/projects")
        XCTAssertEqual(env["OSSUNO_MCP_DEFAULT_BUCKET"] as? String, "prod")
        XCTAssertEqual(ossuno["command"] as? String, "npx")
    }

    func testTOMLReinstallPreservesEnvAndFollowingTables() {
        let source = """
        [mcp_servers.ossuno] # ossuno
        command = "npx"
        args = ["-y", "ossuno-mcp"]
        env = { OSSUNO_MCP_DEFAULT_BUCKET = "prod" }

        [mcp_servers.github] # github
        command = "github-mcp"
        """
        let result = InstallCommand.upsertTOMLSection(
            source,
            section: "mcp_servers.ossuno",
            body: [
                "command = \"npx\"",
                "args = [\"-y\", \"ossuno-mcp\"]",
            ],
            removing: false
        )
        XCTAssertTrue(result.contains("env = { OSSUNO_MCP_DEFAULT_BUCKET = \"prod\" }"))
        XCTAssertTrue(result.contains("[mcp_servers.github]"))
        XCTAssertTrue(result.contains("command = \"github-mcp\""))
        XCTAssertEqual(InstallCommand.tomlTableName("[mcp_servers.github] # github"), "mcp_servers.github")
    }

    func testTOMLReinstallRecognizesQuotedTableAndManagedKeys() {
        let source = """
        [mcp_servers."ossuno"] # quoted spelling is the same TOML table
        "command" = "old-command"
        'args' = ["old"]
        "env" = { OSSUNO_MCP_DEFAULT_BUCKET = "prod" }
        " command " = "must-stay"

        [mcp_servers.github]
        command = "github-mcp"
        """

        let result = InstallCommand.upsertTOMLSection(
            source,
            section: "mcp_servers.ossuno",
            body: [
                "command = \"npx\"",
                "args = [\"-y\", \"ossuno-mcp\"]",
            ],
            removing: false
        )

        XCTAssertEqual(result.components(separatedBy: "[mcp_servers.ossuno]").count - 1, 1)
        XCTAssertFalse(result.contains("old-command"))
        XCTAssertFalse(result.contains("'args'"))
        XCTAssertTrue(result.contains("\"env\" = { OSSUNO_MCP_DEFAULT_BUCKET = \"prod\" }"))
        XCTAssertTrue(result.contains("\" command \" = \"must-stay\""))
        XCTAssertTrue(result.contains("[mcp_servers.github]"))
        XCTAssertEqual(InstallCommand.tomlTableName("[mcp_servers.\"ossuno\"] # note"), "mcp_servers.ossuno")
    }
}
