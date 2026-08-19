import AssistantPlatform
import AssistantPlatformApple
import XCTest

/// Permission answers, translated.
///
/// Worth testing rather than eyeballing because the mapping is where "some
/// access" gets quietly rounded up to "yes". Every case below is a decision
/// about what the app is allowed to claim it can do.
final class PermissionMappingTests: XCTestCase {

    // MARK: Only yes means yes

    func testOnlyFullAccessAllowsTheAppToAct() {
        for authorization in AppleCalendarAuthorization.allCases {
            XCTAssertEqual(
                authorization.permissionStatus.allowsAccess,
                authorization == .fullAccess,
                "\(authorization.rawValue) must not be treated as permission to act"
            )
        }
        for authorization in AppleReminderAuthorization.allCases {
            XCTAssertEqual(
                authorization.permissionStatus.allowsAccess,
                authorization == .fullAccess
            )
        }
        for authorization in AppleNotificationAuthorization.allCases {
            XCTAssertEqual(
                authorization.permissionStatus.allowsAccess,
                authorization == .authorized
            )
        }
        for authorization in AppleAlarmAuthorization.allCases {
            XCTAssertEqual(
                authorization.permissionStatus.allowsAccess,
                authorization == .authorized
            )
        }
    }

    /// "Add Events Only" is a real answer, not a refusal — and not a yes.
    /// Rounding it to `granted` would let the app report an empty schedule for
    /// a full day, which is the worst thing a planning assistant can get wrong.
    func testAddEventsOnlyIsPartialAccessRatherThanEitherAnswer() {
        let status = AppleCalendarAuthorization.writeOnly.permissionStatus
        XCTAssertEqual(status, .limited)
        XCTAssertFalse(status.allowsAccess)
        XCTAssertNotEqual(status, .denied)
    }

    /// A provisional notification is delivered silently to Notification Centre.
    /// The app would believe it was reminding someone who was hearing nothing.
    func testProvisionalNotificationsAreNotCountedAsWorkingNotifications() {
        XCTAssertEqual(AppleNotificationAuthorization.provisional.permissionStatus, .limited)
        XCTAssertEqual(AppleNotificationAuthorization.ephemeral.permissionStatus, .limited)
    }

    /// Restricted means a parent, an employer or a device policy said no. The
    /// person holding the phone cannot change it, so telling them to visit
    /// Settings would send them looking for a switch that is not there.
    func testRestrictedIsKeptDistinctFromDenied() {
        XCTAssertEqual(AppleCalendarAuthorization.restricted.permissionStatus, .restricted)
        XCTAssertNotEqual(
            AppleCalendarAuthorization.restricted.permissionStatus,
            AppleCalendarAuthorization.denied.permissionStatus
        )
    }

    // MARK: When to ask

    func testOnlyAnUnansweredPromptIsWorthShowing() {
        XCTAssertFalse(PermissionStatus.notDetermined.isSettled)
        for status: PermissionStatus in [.granted, .denied, .restricted, .limited, .unsupported] {
            XCTAssertTrue(
                status.isSettled,
                "\(status.rawValue): iOS shows its alert once, so asking again shows nothing"
            )
        }
    }

    /// `ensure` is the rule "act if allowed, ask once if never asked, otherwise
    /// give up quietly", and it is what stops the assistant re-prompting for a
    /// capability the user declined on every single turn.
    func testEnsureAsksOnlyWhenAskingCouldHelp() async {
        let service = CountingPermissionService(status: .notDetermined)
        _ = await service.ensure(.calendar)
        let asked = await service.requestCount
        XCTAssertEqual(asked, 1)

        let settled = CountingPermissionService(status: .denied)
        _ = await settled.ensure(.calendar)
        let notAsked = await settled.requestCount
        XCTAssertEqual(notAsked, 0, "A declined capability must not be re-prompted")

        let allowed = CountingPermissionService(status: .granted)
        _ = await allowed.ensure(.calendar)
        let neverAsked = await allowed.requestCount
        XCTAssertEqual(neverAsked, 0)
    }
}

/// Counts prompts, so "does this ask?" can be asserted rather than assumed.
private actor CountingPermissionService: PermissionService {
    private let stored: PermissionStatus
    private(set) var requestCount = 0

    init(status: PermissionStatus) {
        self.stored = status
    }

    func status(for capability: PlatformCapability) async -> PermissionStatus { stored }

    @discardableResult
    func request(_ capability: PlatformCapability) async -> PermissionStatus {
        requestCount += 1
        return stored
    }
}
