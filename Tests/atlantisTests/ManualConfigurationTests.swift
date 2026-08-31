import Foundation
import XCTest
@testable import Atlantis

/// Decoded view of the ConnectionPackage handshake JSON, limited to the fields
/// the collector cares about. `passcode` lives at the root, matching the Android fork.
private struct DecodedConnectionPackage: Decodable {
    let passcode: String?
    let device: DecodedDevice
    let project: DecodedProject
}

private struct DecodedDevice: Decodable {
    let name: String
    let model: String
}

private struct DecodedProject: Decodable {
    let name: String
}

final class ConnectionPackagePasscodeTests: XCTestCase {

    func testConnectionPackageOmitsPasscodeWhenAbsent() throws {
        let config = Configuration.default()
        let package = ConnectionPackage(config: config)

        let data = try XCTUnwrap(package.toData())

        // When no passcode is configured, the key must be entirely absent so
        // the official Proxyman app (and any older receiver) stays compatible.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(json.keys.contains("passcode"), "passcode key must be omitted when nil")

        let decoded = try JSONDecoder().decode(DecodedConnectionPackage.self, from: data)
        XCTAssertNil(decoded.passcode)
    }

    func testConnectionPackageIncludesPasscodeAtRootWhenSet() throws {
        let config = Configuration.manual(host: "192.168.1.42", port: 10909, passcode: "s3cr3t")
        let package = ConnectionPackage(config: config)

        let data = try XCTUnwrap(package.toData())

        // Passcode must sit at the root of the JSON (same name/place as Android).
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["passcode"] as? String, "s3cr3t")

        let decoded = try JSONDecoder().decode(DecodedConnectionPackage.self, from: data)
        XCTAssertEqual(decoded.passcode, "s3cr3t")
    }

    func testDefaultConfigurationCarriesPasscodeWhenProvided() {
        let config = Configuration.default(hostName: "MyMac.local", passcode: "abc")
        XCTAssertEqual(config.passcode, "abc")
        XCTAssertNil(config.host, "default() must not set a manual host")
    }
}

final class ConfigurationPathSelectionTests: XCTestCase {

    // The Transporter decides between the manual direct TCP path and Bonjour
    // purely from `config.host != nil`. These tests pin that contract without
    // needing a device or a live socket.

    func testDefaultConfigurationChoosesBonjourPath() {
        let config = Configuration.default(hostName: "MyMac.local")
        XCTAssertNil(config.host, "default() must leave host nil so Transporter uses Bonjour")
        XCTAssertEqual(config.hostName, "MyMac.local")
        XCTAssertEqual(config.port, Configuration.defaultPort)
    }

    func testManualConfigurationChoosesDirectPath() {
        let config = Configuration.manual(host: "10.0.0.5", port: 9000, passcode: nil)
        XCTAssertEqual(config.host, "10.0.0.5", "manual() must set host so Transporter skips Bonjour")
        XCTAssertEqual(config.port, 9000)
        XCTAssertNil(config.hostName, "manual() must not set the Bonjour hostName filter")
    }

    func testManualConfigurationDefaultsToProxymanPort() {
        let config = Configuration.manual(host: "10.0.0.5")
        XCTAssertEqual(config.port, 10909)
    }
}
