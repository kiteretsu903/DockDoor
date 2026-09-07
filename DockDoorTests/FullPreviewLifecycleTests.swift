import AppKit
@testable import DockDoor
import Testing

@Suite(.serialized)
@MainActor
struct FullPreviewLifecycleTests {
    private func withPreview(visible: Bool = true, _ body: (SharedPreviewWindowCoordinator) throws -> Void) rethrows {
        let previousCoordinator = SharedPreviewWindowCoordinator.activeInstance
        let coordinator = SharedPreviewWindowCoordinator()
        defer {
            coordinator.hideWindow()
            SharedPreviewWindowCoordinator.activeInstance = previousCoordinator
        }
        if visible {
            coordinator.setFrame(NSRect(x: 0, y: 0, width: 1, height: 1), display: false)
            coordinator.orderFront(nil)
        }
        try body(coordinator)
    }

    @Test func hiddenParentCannotStartFullPreviewHover() {
        withPreview(visible: false) { coordinator in
            #expect(coordinator.beginFullPreviewHover() == nil)
            #expect(!coordinator.isFullPreviewHoverActive(nil))
        }
    }

    @Test func hoverIsValidOnlyWhileParentIsVisible() throws {
        try withPreview { coordinator in
            let hoverID = try #require(coordinator.beginFullPreviewHover())
            #expect(coordinator.isFullPreviewHoverActive(hoverID))
            coordinator.orderOut(nil)
            #expect(!coordinator.isFullPreviewHoverActive(hoverID))
        }
    }

    @Test func cancellationInvalidatesPendingFullPreview() throws {
        try withPreview { coordinator in
            let hoverID = try #require(coordinator.beginFullPreviewHover())
            coordinator.cancelFullPreviewHover(hoverID)
            #expect(coordinator.isVisible)
            #expect(!coordinator.isFullPreviewHoverActive(hoverID))
        }
    }

    @Test func oldCardCleanupDoesNotCancelNewHover() throws {
        try withPreview { coordinator in
            let oldHoverID = try #require(coordinator.beginFullPreviewHover())
            let newHoverID = try #require(coordinator.beginFullPreviewHover())
            #expect(!coordinator.isFullPreviewHoverActive(oldHoverID))
            coordinator.cancelFullPreviewHover(oldHoverID)
            #expect(coordinator.isFullPreviewHoverActive(newHoverID))
            coordinator.cancelFullPreviewHover(newHoverID)
            #expect(!coordinator.isFullPreviewHoverActive(newHoverID))
        }
    }

    @Test func dismissalKeepsOldRequestsInvalidAfterReopening() throws {
        try withPreview { coordinator in
            let oldHoverID = try #require(coordinator.beginFullPreviewHover())
            coordinator.hideWindow()
            coordinator.orderFront(nil)
            #expect(!coordinator.isFullPreviewHoverActive(oldHoverID))
            let newHoverID = try #require(coordinator.beginFullPreviewHover())
            coordinator.cancelFullPreviewHover(oldHoverID)
            #expect(coordinator.isFullPreviewHoverActive(newHoverID))
        }
    }

    @Test func hidingFullPreviewInvalidatesHoverWithoutHidingParent() throws {
        try withPreview { coordinator in
            let hoverID = try #require(coordinator.beginFullPreviewHover())
            coordinator.hideFullPreviewWindow()
            #expect(coordinator.isVisible)
            #expect(!coordinator.isFullPreviewHoverActive(hoverID))
        }
    }
}
