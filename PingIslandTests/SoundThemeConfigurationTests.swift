import XCTest
@testable import Ping_Island

final class SoundThemeConfigurationTests: XCTestCase {
    func testIsland8BitThemeModeIsAvailable() {
        XCTAssertTrue(SoundThemeMode.allCases.contains(.island8Bit))
        XCTAssertEqual(SoundThemeMode.island8Bit.title, "内置 8-bit")
        XCTAssertEqual(
            SoundThemeMode(rawValue: "missing-theme") ?? .island8Bit,
            .island8Bit
        )
    }

    func testIsland8BitEventMappingsMatchSelectedPreset() {
        XCTAssertEqual(NotificationEvent.processingStarted.island8BitSound, .processingStarted)
        XCTAssertEqual(NotificationEvent.approvalRequired.island8BitSound, .approvalRequired)
        XCTAssertEqual(NotificationEvent.attentionRequired.island8BitSound, .attentionRequired)
        XCTAssertEqual(NotificationEvent.taskCompleted.island8BitSound, .taskCompleted)
        XCTAssertEqual(NotificationEvent.taskError.island8BitSound, .taskError)
        XCTAssertEqual(NotificationEvent.resourceLimit.island8BitSound, .resourceLimit)
    }

    func testIsland8BitStartupAndSharedLabelsStayStable() {
        XCTAssertEqual(Island8BitSound.clientStartup.rawValue, "island8bit_client_startup")
        XCTAssertEqual(Island8BitSound.clientStartup.label, "Power Up")
        XCTAssertEqual(Island8BitSound.processingStarted.label, "Menu Select")
        XCTAssertEqual(Island8BitSound.approvalRequired.rawValue, "8bit_approval")
        XCTAssertEqual(Island8BitSound.approvalRequired.label, "Approval Alert")
        XCTAssertEqual(Island8BitSound.attentionRequired.label, "Item Pickup")
        XCTAssertEqual(Island8BitSound.taskCompleted.label, "Menu Highlight")
        XCTAssertEqual(Island8BitSound.taskError.label, "Hurt")
        XCTAssertEqual(Island8BitSound.resourceLimit.label, "Hurt")
    }
}
