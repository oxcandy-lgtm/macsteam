// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacSteam

struct RecipeSecurityTests {

    // MARK: - Forbidden operation kinds

    @Test func testShellOperationRejected() {
        let json = """
        {
            "kind": "runShell",
            "value": "rm -rf /"
        }
        """
        let data = json.data(using: .utf8)!
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(RecipeOperation.self, from: data)
        }
    }

    @Test func testSudoOperationRejected() {
        let json = """
        {
            "kind": "runSudo",
            "value": "sudo rm -rf /"
        }
        """
        let data = json.data(using: .utf8)!
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(RecipeOperation.self, from: data)
        }
    }

    @Test func testDeleteHostPathRejected() {
        let json = """
        {
            "kind": "deleteHostPath",
            "value": "/etc/passwd"
        }
        """
        let data = json.data(using: .utf8)!
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(RecipeOperation.self, from: data)
        }
    }

    @Test func testDownloadArbitraryURLRejected() {
        let json = """
        {
            "kind": "downloadArbitraryURL",
            "value": "https://evil.com/malware.sh"
        }
        """
        let data = json.data(using: .utf8)!
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(RecipeOperation.self, from: data)
        }
    }

    // MARK: - Unknown env key rejection

    @Test func testUnknownEnvKeyRejected() {
        // Attempt to decode AllowedEnvironmentMutation with an unknown env key
        let json = """
        {
            "key": "MY_CUSTOM_SECRET",
            "value": "s3kr3t"
        }
        """
        let data = json.data(using: .utf8)!
        #expect(throws: Swift.DecodingError.self) {
            _ = try JSONDecoder().decode(AllowedEnvironmentMutation.self, from: data)
        }
    }

    // MARK: - Allowed operations

    @Test func testAllowedWindowsVersion() throws {
        let json = """
        {
            "kind": "setWindowsVersion",
            "value": "win10"
        }
        """
        let data = json.data(using: .utf8)!
        let operation = try JSONDecoder().decode(RecipeOperation.self, from: data)
        #expect(operation == .setWindowsVersion("win10"))
    }

    @Test func testAllowedRegistryMutation() throws {
        let json = """
        {
            "kind": "setRegistryValue",
            "value": {
                "key": "HKEY_CURRENT_USER\\\\Software\\\\Valve\\\\Steam",
                "value": "RunningAppID",
                "data": "3314790"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let operation = try JSONDecoder().decode(RecipeOperation.self, from: data)
        guard case .setRegistryValue(let mutation) = operation else {
            Issue.record("Expected setRegistryValue, got \(operation)")
            return
        }
        #expect(mutation.key == "HKEY_CURRENT_USER\\Software\\Valve\\Steam")
        #expect(mutation.value == "RunningAppID")
        #expect(mutation.data == "3314790")
    }

    @Test func testAllowedDLLOverride() throws {
        let json = """
        {
            "kind": "setDLLOverride",
            "value": {
                "library": "d3d11",
                "mode": "native"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let operation = try JSONDecoder().decode(RecipeOperation.self, from: data)
        guard case .setDLLOverride(let override) = operation else {
            Issue.record("Expected setDLLOverride, got \(operation)")
            return
        }
        #expect(override.library == "d3d11")
        #expect(override.mode == .native)
    }

    @Test func testAllowedEnvironmentMutation() throws {
        let json = """
        {
            "kind": "setEnvironment",
            "value": {
                "key": "WINEPREFIX",
                "value": "/path/to/prefix"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let operation = try JSONDecoder().decode(RecipeOperation.self, from: data)
        guard case .setEnvironment(let mutation) = operation else {
            Issue.record("Expected setEnvironment, got \(operation)")
            return
        }
        #expect(mutation.key == .winprefix)
        #expect(mutation.value == "/path/to/prefix")
    }

    @Test func testAllowedCopyBundledComponent() throws {
        let json = """
        {
            "kind": "copyBundledOpenSourceComponent",
            "value": {
                "sourceRelativePath": "dxvk/x64/d3d11.dll",
                "destinationRelativePath": "drive_c/windows/system32/d3d11.dll"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let operation = try JSONDecoder().decode(RecipeOperation.self, from: data)
        guard case .copyBundledOpenSourceComponent(let copy) = operation else {
            Issue.record("Expected copyBundledOpenSourceComponent, got \(operation)")
            return
        }
        #expect(copy.sourceRelativePath == "dxvk/x64/d3d11.dll")
        #expect(copy.destinationRelativePath == "drive_c/windows/system32/d3d11.dll")
    }

    @Test func testAllowedVerifyFile() throws {
        let json = """
        {
            "kind": "verifyFile",
            "value": {
                "relativePath": "drive_c/Program Files/Steam/steam.exe"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let operation = try JSONDecoder().decode(RecipeOperation.self, from: data)
        guard case .verifyFile(let verification) = operation else {
            Issue.record("Expected verifyFile, got \(operation)")
            return
        }
        #expect(verification.relativePath == "drive_c/Program Files/Steam/steam.exe")
    }
}
