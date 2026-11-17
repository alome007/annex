import XCTest
@testable import HAOSRunner

/// Requirements: a chosen USB device is recognised again after it is unplugged
/// or Annex relaunches, and adding USB support never throws away a session
/// suspended by a build without it.
final class USBPassthroughTests: XCTestCase {
    /// A CP2102N serial bridge, the chip on Sonoff's Zigbee dongles: vendor
    /// 10c4, product ea60.
    private let descriptor = Data([
        0x12, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x40, 0xC4, 0x10,
        0x60, 0xEA, 0x00, 0x01, 0x01, 0x02, 0x03, 0x01,
    ])
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "haosrunner-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testIDsComeFromTheDeviceDescriptor() throws {
        let device = try XCTUnwrap(USBDevice(name: "Zigbee dongle", serial: "a1", deviceDescriptor: descriptor))
        XCTAssertEqual(device.vendorID, 0x10C4)
        XCTAssertEqual(device.productID, 0xEA60)
    }

    func testDeviceWithoutANameIsLabelledByItsIDs() throws {
        let device = try XCTUnwrap(USBDevice(name: nil, serial: nil, deviceDescriptor: descriptor))
        XCTAssertEqual(device.name, "USB device 10c4:ea60")
    }

    func testTruncatedDescriptorIsRejected() {
        XCTAssertNil(USBDevice(name: "Zigbee dongle", serial: nil, deviceDescriptor: descriptor.prefix(8)))
    }

    func testChosenDeviceIsStoredSoTheNextLaunchReadsIt() throws {
        var settings = VMSettings()
        settings.usbDevice = USBDevice(name: "Zigbee dongle", vendorID: 0x10C4, productID: 0xEA60, serial: "a1")
        settings.save(to: defaults)
        let nextLaunch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(VMSettings.load(from: nextLaunch).usbDevice, settings.usbDevice)
    }

    func testClearingTheChoiceIsStoredToo() throws {
        var settings = VMSettings()
        settings.usbDevice = USBDevice(name: "Zigbee dongle", vendorID: 0x10C4, productID: 0xEA60, serial: nil)
        settings.save(to: defaults)
        settings.usbDevice = nil
        settings.save(to: defaults)
        XCTAssertNil(VMSettings.load(from: defaults).usbDevice)
    }

    func testSessionsSuspendedWithoutAUSBControllerKeepTheirFingerprint() {
        XCTAssertEqual(SavedSession.fingerprint(VMSettings(), usbController: false), "4gb-4cpu-nat")
    }

    func testAddingTheUSBControllerChangesTheFingerprint() {
        XCTAssertNotEqual(
            SavedSession.fingerprint(VMSettings(), usbController: true),
            SavedSession.fingerprint(VMSettings(), usbController: false)
        )
    }

    /// The device is plugged in after the machine starts, so choosing another
    /// one must not cost the suspended session.
    func testChoosingADeviceKeepsTheFingerprint() {
        var withDevice = VMSettings()
        withDevice.usbDevice = USBDevice(name: "Zigbee dongle", vendorID: 0x10C4, productID: 0xEA60, serial: nil)
        XCTAssertEqual(
            SavedSession.fingerprint(withDevice, usbController: true),
            SavedSession.fingerprint(VMSettings(), usbController: true)
        )
    }
}
