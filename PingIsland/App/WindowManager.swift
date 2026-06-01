//
//  WindowManager.swift
//  PingIsland
//
//  Manages the notch window lifecycle
//

import AppKit
import os.log

/// Logger for window management
private let logger = Logger(subsystem: "io.github.liuyuplus.jadecub", category: "Window")

@MainActor
class WindowManager {
    private(set) var presentationCoordinator: IslandPresentationCoordinator?
    private var activeScreenNumber: NSNumber?

    /// Set up or recreate the notch window
    func setupNotchWindow() -> NotchWindowController? {
        // Use ScreenSelector for screen selection
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return nil
        }

        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if let presentationCoordinator,
           activeScreenNumber == screenNumber {
            presentationCoordinator.updateScreen(screen)
            return nil
        }

        presentationCoordinator?.invalidate()
        let presentationCoordinator = IslandPresentationCoordinator(screen: screen)
        self.presentationCoordinator = presentationCoordinator
        activeScreenNumber = screenNumber
        return nil
    }
}
