//
//  keroApp.swift
//  kero
//

import SwiftUI

struct keroApp: App {
    @NSApplicationDelegateAdaptor(KeroApplicationDelegate.self)
    private var applicationDelegate

    // Held here so Sparkle starts at launch and background checks run even if
    // the menu is never opened.
    @StateObject private var updater = Updater.shared

    init() {
        TerminalFont.registerBundledFonts()
        TerminalNotificationService.shared.configure()
        AppSettings.shared.reconcileAIEnabled()
    }

    var body: some Scene {
        WindowGroup("kero", id: "main") {
            WindowRootView()
        }
        .windowStyle(.hiddenTitleBar)
        // Keep title-bar dragging away from interactive tabs. The empty
        // header surfaces opt in explicitly through WindowDragArea.
        .windowBackgroundDragBehavior(.disabled)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            KeroCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Root of one terminal window. Each window owns its own manager, which
/// claims the next unclaimed window snapshot; the first window to appear
/// reopens windows for any snapshots left over.
private struct WindowRootView: View {
    @StateObject private var manager = TerminalManager()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(manager: manager)
            .focusedSceneObject(manager)
            .onAppear {
                TerminalManager.openRestoredWindows {
                    openWindow(id: "main")
                }
            }
            .onDisappear {
                manager.windowClosed()
            }
    }
}

/// Menu commands routed to the focused window's manager.
private struct KeroCommands: Commands {
    @FocusedObject private var manager: TerminalManager?
    @Environment(\.openWindow) private var openWindow
    /// Observed so rebinding a shortcut in Settings rebuilds these menus:
    /// `keroShortcut` reads the map, and a menu that kept a stale key
    /// equivalent would disagree with what the keyboard actually does.
    @ObservedObject private var settings = AppSettings.shared

    var body: some Commands {
        let _ = TerminalManager.registerWindowOpener {
            openWindow(id: "main")
        }

        CommandGroup(replacing: .newItem) {
            Button("New Project") {
                manager?.newProject()
            }
            .keroShortcut(.newProject, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("New Session") {
                manager?.newSession()
            }
            .keroShortcut(.newSession, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("New Browser Tab") {
                manager?.newBrowserTab()
            }
            .keroShortcut(.newBrowserTab, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("New Window") {
                openWindow(id: "main")
            }
            .keroShortcut(.newWindow, in: settings.shortcuts)

            Button("Close Pane") {
                // Cmd-W is app-wide: close a pane only when a main window with
                // an open project is key. Otherwise close the key window
                // itself — a non-main window (e.g. Settings), or a main window
                // showing the empty "No open projects" state with no tab left.
                if let manager, manager.selectedProject != nil,
                   NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true {
                    manager.closeSelectedTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keroShortcut(.closePane, in: settings.shortcuts)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                manager?.saveSelectedFile()
            }
            .keroShortcut(.saveFile, in: settings.shortcuts)
            .disabled(manager == nil)
        }

        CommandGroup(after: .pasteboard) {
            // SwiftUI's Edit menu ships no Find submenu, so Kero owns these
            // outright. They act on the focused pane — Ghostty's search in a
            // terminal, STTextView's find bar in a file editor — rather than on
            // the first responder, which keeps them live while the find bar's
            // text field has keyboard focus. ⇧⌘G is already Toggle Git Panel,
            // so Find Previous is reachable by ⇧↩ in the bar instead.
            Menu("Find") {
                Button("Find…") {
                    manager?.performFindAction(.show)
                }
                .keroShortcut(.find, in: settings.shortcuts)
                .disabled(manager?.canFind != true)

                Button("Find and Replace…") {
                    manager?.performFindAction(.replace)
                }
                .keroShortcut(.findAndReplace, in: settings.shortcuts)
                .disabled(manager?.canReplace != true)

                Button("Find Next") {
                    manager?.performFindAction(.next)
                }
                .keroShortcut(.findNext, in: settings.shortcuts)
                .disabled(manager?.canFind != true)

                Button("Find Previous") {
                    manager?.performFindAction(.previous)
                }
                .disabled(manager?.canFind != true)

                Button("Use Selection for Find") {
                    manager?.performFindAction(.useSelection)
                }
                .keroShortcut(.useSelectionForFind, in: settings.shortcuts)
                .disabled(manager?.canFind != true)
            }

            Divider()

            Button("Clear Terminal") {
                manager?.clearActiveTerminal()
            }
            .keroShortcut(.clearTerminal, in: settings.shortcuts)
            .disabled(manager?.canClearActiveTerminal != true)
        }

        // Frees ⌘P from the default Print item for the command palette.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .sidebar) {
            Button("Command Palette…") {
                manager?.toggleCommandPalette()
            }
            .keroShortcut(.commandPalette, in: settings.shortcuts)
            .disabled(manager == nil)

            Divider()

            Button("Toggle Left Sidebar") {
                manager?.toggleLeftSidebar()
            }
            .keroShortcut(.toggleLeftSidebar, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("Toggle Right Sidebar") {
                manager?.toggleSidebar()
            }
            .keroShortcut(.toggleRightSidebar, in: settings.shortcuts)
            .disabled(manager?.selectedProject == nil)

            Button("Toggle Files Panel") {
                manager?.togglePanel(.files)
            }
            .keroShortcut(.toggleFilesPanel, in: settings.shortcuts)
            .disabled(manager?.selectedProject == nil)

            Button("Toggle Git Panel") {
                manager?.togglePanel(.git)
            }
            .keroShortcut(.toggleGitPanel, in: settings.shortcuts)
            .disabled(manager?.selectedProject == nil)

            Button("Toggle Info Panel") {
                manager?.togglePanel(.info)
            }
            .keroShortcut(.toggleInfoPanel, in: settings.shortcuts)
            .disabled(manager?.selectedProject == nil)
        }

        CommandMenu("Projects") {
            Button("Next Project") {
                manager?.selectNextProject()
            }
            .keroShortcut(.nextProject, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("Previous Project") {
                manager?.selectPreviousProject()
            }
            .keroShortcut(.previousProject, in: settings.shortcuts)
            .disabled(manager == nil)

            Divider()

            ForEach(Array((manager?.projects ?? []).prefix(9).enumerated()), id: \.element.id) { index, project in
                Button(project.name) {
                    manager?.selectProject(index: index)
                }
                .keroNumberShortcut(.selectWorkspaceNumber, index: index, in: settings.shortcuts)
            }
        }

        CommandMenu("Browser") {
            Button("Focus Address Bar") {
                manager?.focusBrowserAddressBar()
            }
            .keroShortcut(.focusAddressBar, in: settings.shortcuts)
            .disabled(manager?.hasSelectedBrowser != true)

            Button("Reload Page") {
                manager?.reloadSelectedBrowser()
            }
            .keroShortcut(.reloadPage, in: settings.shortcuts)
            .disabled(manager?.hasSelectedBrowser != true)

            Button("Stop Loading") {
                manager?.stopSelectedBrowser()
            }
            .disabled(manager?.hasSelectedBrowser != true)

            Divider()

            Button("Open in Default Browser") {
                manager?.openSelectedPageInDefaultBrowser()
            }
            .disabled(manager?.hasSelectedBrowser != true)
        }

        CommandMenu("Agents") {
            Button("Next Agent Needing Attention") {
                manager?.focusNextAgentAttention()
            }
            .keroShortcut(.nextAgentAttention, in: settings.shortcuts)
            .disabled(manager?.hasAgentAttention != true)
        }

        CommandMenu("Tabs") {
            Button("Split Right") {
                manager?.splitRight()
            }
            .keroShortcut(.splitRight, in: settings.shortcuts)
            .disabled(manager?.canSplit != true)

            Button("Split Down") {
                manager?.splitDown()
            }
            .keroShortcut(.splitDown, in: settings.shortcuts)
            .disabled(manager?.canSplit != true)

            Button("Split Left") {
                manager?.splitLeft()
            }
            .keroShortcut(.splitLeft, in: settings.shortcuts)
            .disabled(manager?.canSplit != true)

            Button("Split Up") {
                manager?.splitUp()
            }
            .keroShortcut(.splitUp, in: settings.shortcuts)
            .disabled(manager?.canSplit != true)

            Divider()

            Button("Focus Pane Left") {
                manager?.focusPaneLeft()
            }
            .keroShortcut(.focusPaneLeft, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("Focus Pane Right") {
                manager?.focusPaneRight()
            }
            .keroShortcut(.focusPaneRight, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("Focus Pane Up") {
                manager?.focusPaneUp()
            }
            .keroShortcut(.focusPaneUp, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("Focus Pane Down") {
                manager?.focusPaneDown()
            }
            .keroShortcut(.focusPaneDown, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("Focus Previous Pane") {
                manager?.focusPreviousPane()
            }
            .keroShortcut(.focusPreviousPane, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("Focus Next Pane") {
                manager?.focusNextPane()
            }
            .keroShortcut(.focusNextPane, in: settings.shortcuts)
            .disabled(manager == nil)

            Divider()

            Button("Toggle Pane Zoom") {
                manager?.togglePaneZoom()
            }
            .keroShortcut(.togglePaneZoom, in: settings.shortcuts)
            .disabled(manager?.hasSplitPanes != true)

            Button("Equalize Panes") {
                manager?.equalizePanes()
            }
            .keroShortcut(.equalizePanes, in: settings.shortcuts)
            .disabled(manager?.hasSplitPanes != true)

            Menu("Resize Pane") {
                Button("Up") {
                    manager?.resizePaneUp()
                }
                .keroShortcut(.resizePaneUp, in: settings.shortcuts)
                .disabled(manager?.hasSplitPanes != true)

                Button("Down") {
                    manager?.resizePaneDown()
                }
                .keroShortcut(.resizePaneDown, in: settings.shortcuts)
                .disabled(manager?.hasSplitPanes != true)

                Button("Left") {
                    manager?.resizePaneLeft()
                }
                .keroShortcut(.resizePaneLeft, in: settings.shortcuts)
                .disabled(manager?.hasSplitPanes != true)

                Button("Right") {
                    manager?.resizePaneRight()
                }
                .keroShortcut(.resizePaneRight, in: settings.shortcuts)
                .disabled(manager?.hasSplitPanes != true)
            }

            Divider()

            Button("Next Tab") {
                manager?.selectNextTab()
            }
            .keroShortcut(.nextTab, in: settings.shortcuts)
            .disabled(manager == nil)

            Button("Previous Tab") {
                manager?.selectPreviousTab()
            }
            .keroShortcut(.previousTab, in: settings.shortcuts)
            .disabled(manager == nil)

            Divider()

            ForEach(Array((manager?.selectedProject?.tabs ?? []).prefix(9).enumerated()), id: \.element.id) { index, tab in
                Button(tab.displayTitle ?? String(localized: "Tab \(index + 1)")) {
                    manager?.selectTab(index: index)
                }
                .keroNumberShortcut(.selectTabNumber, index: index, in: settings.shortcuts)
            }
        }
    }
}
