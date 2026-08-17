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

    func testDecodesReleaseListKeepingOnlyStableAarch64Releases() throws {
        let json = """
        [
          {"tag_name": "19.0.rc1", "prerelease": true,
           "html_url": "https://github.com/home-assistant/operating-system/releases/tag/19.0.rc1", "assets": [{"name": "haos_generic-aarch64-19.0.rc1.img.xz", "browser_download_url": "https://example.com/rc.img.xz"}]},
          {"tag_name": "18.2", "prerelease": false, "html_url": "https://github.com/home-assistant/operating-system/releases/tag/18.2",
           "assets": [{"name": "haos_generic-aarch64-18.2.qcow2.xz", "browser_download_url": "https://example.com/18.2.qcow2.xz"},
                      {"name": "haos_generic-aarch64-18.2.img.xz", "browser_download_url": "https://example.com/18.2.img.xz"}]},
          {"tag_name": "18.1", "prerelease": false, "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"}]},
          {"tag_name": "18.0", "prerelease": false,
           "assets": [{"name": "haos_generic-aarch64-18.0.img.xz", "browser_download_url": "https://example.com/18.0.img.xz"}]}
        ]
        """
        let releases = try XCTUnwrap(ImageDownloader.releases(fromJSON: Data(json.utf8)))
        XCTAssertEqual(releases.map(\.version), ["18.2", "18.0"])
        XCTAssertEqual(releases.first?.assetName, "haos_generic-aarch64-18.2.img.xz")
        XCTAssertEqual(releases.first?.assetURL.absoluteString, "https://example.com/18.2.img.xz")
        XCTAssertEqual(
            releases.first?.notesURL?.absoluteString,
            "https://github.com/home-assistant/operating-system/releases/tag/18.2"
        )
        XCTAssertNil(releases.last?.notesURL)
    }

    func testReleaseDecodeRejectsMalformedJSON() {
        XCTAssertNil(ImageDownloader.releases(fromJSON: Data("not json".utf8)))
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
