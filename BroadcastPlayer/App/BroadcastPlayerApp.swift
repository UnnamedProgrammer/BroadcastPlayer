import AppKit
import OSLog
import SwiftUI

@main
struct BroadcastPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("Broadcast Player", id: WindowID.main) {
            MainView()
                .environment(appState)
        }
        .defaultSize(width: 960, height: 600)
        .commands {
            CommandMenu("Audio") {
                Button(appState.audio.isMuted ? "Unmute" : "Mute") {
                    appState.audio.updateMuted(!appState.audio.isMuted)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!appState.audio.isEnabled)
            }
            CommandMenu("Video") {
                Button(appState.comparesOriginal ? "End comparison" : "Compare original / enhanced") {
                    appState.updateComparison(!appState.comparesOriginal)
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!appState.canCompare)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

enum WindowID {
    static let main = "main"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        Log.lifecycle.info("applicationDidFinishLaunching — macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.lifecycle.info("applicationWillTerminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Log.lifecycle.info("last window closed — terminating")
        return true
    }
}