import XCTest
@testable import HAOSRunner

final class ImageAssetMatchingTests: XCTestCase {
    func testPicksAarch64ImageArchive() {
        let names = [
            "haos_generic-aarch64-18.2.qcow2.xz",
            "haos_generic-aarch64-18.2.img.xz",
            "haos_generic-aarch64-18.2.raucb",
            "haos_generic-x86-64-18.2.img.xz",
            "haos_ova-18.2.vmdk.zip",
        ]
        XCTAssertEqual(ImageDownloader.imageAssetName(inReleaseAssetNames: names), "haos_generic-aarch64-18.2.img.xz")
    }

    func testReturnsNilWhenNoMatchingAsset() {
        XCTAssertNil(ImageDownloader.imageAssetName(inReleaseAssetNames: ["haos_ova-18.2.qcow2.xz", "notes.txt"]))
    }

    func testExtractsVersionFromRedirectLocation() {
        XCTAssertEqual(
            ImageDownloader.versionTag(fromRedirectLocation: "https://github.com/home-assistant/operating-system/releases/tag/18.2"),
            "18.2"
        )
    }

    func testRejectsUnexpectedRedirectLocations() {
        XCTAssertNil(ImageDownloader.versionTag(fromRedirectLocation: "https://github.com/home-assistant/operating-system/releases"))
        XCTAssertNil(ImageDownloader.versionTag(fromRedirectLocation: "not a url at all ::"))
    }

    func testBuildsDeterministicImageURL() {
        XCTAssertEqual(
            ImageDownloader.imageURL(forVersion: "18.2")?.absoluteString,
            "https://github.com/home-assistant/operating-system/releases/download/18.2/haos_generic-aarch64-18.2.img.xz"
        )
    }
}

final class DiskSourceTests: XCTestCase {
    private let user = URL(fileURLWithPath: "/tmp/custom.qcow2")
    private let cached = URL(fileURLWithPath: "/tmp/haos_generic-aarch64-18.2.img.xz")

    func testUserImageWinsOverCachedArchive() {
        XCTAssertEqual(DiskSource.resolve(userImage: user, cachedArchive: cached), .qcow2(user))
    }

    func testUserImageKindsByExtension() {
        XCTAssertEqual(
            DiskSource.resolve(userImage: URL(fileURLWithPath: "/tmp/a.img"), cachedArchive: nil),
            .rawImage(URL(fileURLWithPath: "/tmp/a.img"))
        )
        XCTAssertEqual(
            DiskSource.resolve(userImage: URL(fileURLWithPath: "/tmp/a.img.xz"), cachedArchive: nil),
            .xzArchive(URL(fileURLWithPath: "/tmp/a.img.xz"))
        )
    }

    func testCachedArchiveUsedWithoutUserImage() {
        XCTAssertEqual(DiskSource.resolve(userImage: nil, cachedArchive: cached), .xzArchive(cached))
    }

    func testNoSources() {
        XCTAssertEqual(DiskSource.resolve(userImage: nil, cachedArchive: nil), .none)
    }
}
