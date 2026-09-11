import Foundation
import XCTest
@testable import Atlantis

/// Decoded view of the ConnectionPackage handshake JSON, limited to the fields
/// the collector cares about. `passcode` lives at the root, matching the Android fork.
private struct DecodedConnectionPackage: Decodable {
    let passcode: String?
    let appVersion: String?
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

    func testConnectionPackageAppVersionMatchesBundleAtRoot() throws {
        let config = Configuration.default()
        let package = ConnectionPackage(config: config)

        let data = try XCTUnwrap(package.toData())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // appVersion mirrors CFBundleShortVersionString: present at the root when
        // the bundle exposes it, omitted otherwise. Don't assume a value, since the
        // test runner's Info.plist may not carry one.
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let bundleVersion = bundleVersion {
            XCTAssertEqual(json["appVersion"] as? String, bundleVersion)
        } else {
            XCTAssertFalse(json.keys.contains("appVersion"), "appVersion key must be omitted when the bundle has no version")
        }
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

final class ConfigurationDeviceKeyTests: XCTestCase {

    // The envelope `id` is what the collector uses to distinguish a device. A supplied
    // deviceKey must become that id so the collector can unify this device with the
    // ingest hello it already registered.

    func testDeviceKeyBecomesEnvelopeIdWhenSet() {
        let config = Configuration.manual(host: "10.0.0.5", tls: nil, deviceKey: "android-1kgza26-ca75c427")
        XCTAssertEqual(config.id, "android-1kgza26-ca75c427")
        XCTAssertEqual(config.deviceKey, "android-1kgza26-ca75c427")
    }

    func testAbsentDeviceKeyKeepsLegacyBundleModelId() {
        // No deviceKey: the id must stay the historical bundleId-model composition,
        // identical to what the default (Bonjour) configuration produces.
        let manual = Configuration.manual(host: "10.0.0.5")
        let legacy = Configuration.default()
        XCTAssertNil(manual.deviceKey)
        XCTAssertEqual(manual.id, legacy.id, "absent deviceKey must not change the id")
        XCTAssertNotEqual(manual.id, "", "legacy id must be the bundleId-model composition")
    }

    func testDeviceKeyDoesNotAlterReadableDeviceNameOrModel() throws {
        // The readable device name/model live in a separate field (ConnectionPackage.device)
        // and must be identical with or without a deviceKey — the change is purely additive.
        let withKey = ConnectionPackage(config: Configuration.manual(host: "h", tls: nil, deviceKey: "unified-id"))
        let withoutKey = ConnectionPackage(config: Configuration.manual(host: "h"))

        let a = try JSONDecoder().decode(DecodedConnectionPackage.self, from: try XCTUnwrap(withKey.toData()))
        let b = try JSONDecoder().decode(DecodedConnectionPackage.self, from: try XCTUnwrap(withoutKey.toData()))

        XCTAssertEqual(a.device.name, b.device.name)
        XCTAssertEqual(a.device.model, b.device.model)
    }
}
