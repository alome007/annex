import Foundation
// SDKs before macOS 27's have no AccessoryAccess, and CI and releases build
// with one, so everything that touches a real device compiles out there.
#if canImport(AccessoryAccess)
import AccessoryAccess
import IOKit
import Security
import Virtualization
import os
#endif

/// Whether this build can hand USB devices to the machine.
enum USBPassthrough {
    /// macOS kills an app at launch when it claims this entitlement without a
    /// provisioning profile that grants it, so only builds signed with such a
    /// profile carry it.
    static let entitlement = "com.apple.developer.accessory-access.usb"

    static let isAvailable: Bool = {
        #if canImport(AccessoryAccess)
        guard #available(macOS 27, *), let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool == true
        #else
        return false
        #endif
    }()
}

/// A USB device as Annex remembers it, so the same dongle is found again after
/// it is unplugged or the Mac restarts.
struct USBDevice: Codable, Hashable {
    var name: String
    var vendorID: UInt16
    var productID: UInt16
    var serial: String?
}

extension USBDevice {
    /// Reads the vendor and product IDs from a USB device descriptor, which
    /// holds them little-endian at bytes 8 and 10.
    init?(name: String?, serial: String?, deviceDescriptor: Data) {
        let bytes = [UInt8](deviceDescriptor)
        guard bytes.count >= 12 else { return nil }
        let vendorID = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
        let productID = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
        self.init(
            name: name ?? String(format: "USB device %04x:%04x", vendorID, productID),
            vendorID: vendorID,
            productID: productID,
            serial: serial
        )
    }
}

#if canImport(AccessoryAccess)
extension USBDevice {
    /// Describes a device plugged into this Mac, with the names macOS read from it.
    @available(macOS 27, *)
    init?(_ accessory: AAUSBAccessory) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(accessory.registryID))
        defer { IOObjectRelease(service) }
        func string(_ key: String) -> String? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        }
        self.init(
            name: string("USB Product Name"),
            serial: string("USB Serial Number"),
            deviceDescriptor: accessory.deviceDescriptorData
        )
    }
}

/// Watches the USB devices plugged into this Mac and keeps the chosen one
/// plugged into the machine.
///
/// The device is plugged in after the machine starts instead of being written
/// into its configuration. A suspended session then never depends on a device
/// that may be gone by the next launch, and the device can be unplugged before
/// suspending.
@available(macOS 27, *)
@MainActor
final class USBDevices: NSObject {
    /// Devices plugged into this Mac, in the order they arrived.
    private(set) var connected: [(device: USBDevice, accessory: AAUSBAccessory)] = []
    /// Called whenever a device is plugged into or unplugged from this Mac.
    var onChange: () -> Void = {}

    private var attached: (accessory: AAUSBAccessory, device: VZUSBPassthroughDevice, controller: VZUSBController)?
    private let log = Logger(subsystem: "casa.astrohome.haosrunner", category: "usb")

    /// Starts listening and lists the devices already plugged in.
    func start() async throws {
        let present = try await AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: [])
        present.forEach(add)
        onChange()
    }

    /// Plugs `choice` into `machine` when it is plugged into this Mac,
    /// unplugging whatever the machine had before.
    func connect(_ choice: USBDevice?, to machine: VZVirtualMachine) async throws {
        guard let controller = machine.usbControllers.first else {
            preconditionFailure("The machine was configured without the USB controller this build adds")
        }
        // A plug-in still finishing when the last machine stopped left its
        // record behind, and that machine has released the device.
        if attached?.controller !== controller { attached = nil }
        let wanted = connected.first { $0.device == choice }?.accessory
        guard attached?.accessory.registryID != wanted?.registryID else { return }
        try await disconnect()
        guard let wanted else { return }
        let device = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: wanted))
        try await controller.attach(device: device)
        attached = (wanted, device, controller)
        log.notice("plugged USB device \(wanted.registryID, privacy: .public) into the machine")
    }

    /// Unplugs the device from the machine. Done before suspending, so the
    /// saved session holds no device that may be gone when it resumes.
    func disconnect() async throws {
        guard let current = attached else { return }
        attached = nil
        try await current.controller.detach(device: current.device)
    }

    /// Forgets the device once the machine is off, which has released it.
    func machineStopped() {
        attached = nil
    }

    private func add(_ accessory: AAUSBAccessory) {
        guard let device = USBDevice(accessory) else {
            log.error("ignoring USB device \(accessory.registryID, privacy: .public): its descriptor is too short")
            return
        }
        connected.append((device, accessory))
    }

    private func remove(_ accessory: AAUSBAccessory) {
        connected.removeAll { $0.accessory.registryID == accessory.registryID }
        // Virtualization takes an unplugged device out of the machine itself.
        if attached?.accessory.registryID == accessory.registryID { attached = nil }
    }
}

@available(macOS 27, *)
extension USBDevices: AAUSBAccessoryListener {
    nonisolated func usbAccessoryDidConnect(_ accessory: AAUSBAccessory) {
        Task { @MainActor in
            self.add(accessory)
            self.onChange()
        }
    }

    nonisolated func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) {
        Task { @MainActor in
            self.remove(accessory)
            self.onChange()
        }
    }
}
#endif
