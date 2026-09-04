#!/usr/bin/env swift

import CoreGraphics
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func main() {
    if CommandLine.arguments.dropFirst().first == "--help" {
        print("Usage: verify_macos_window_level.swift <electron-pid>")
        return
    }
    guard CommandLine.arguments.count == 2,
          let targetPID = Int32(CommandLine.arguments[1]) else {
        fail("Usage: verify_macos_window_level.swift <electron-pid>")
    }
    guard let raw = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) else {
        fail("CoreGraphics did not return a window list")
    }
    let rows = raw as NSArray as? [[String: Any]] ?? []
    let dockWallpaperLayer = rows.compactMap { row -> Int? in
        let owner = row[kCGWindowOwnerName as String] as? String ?? ""
        let name = row[kCGWindowName as String] as? String ?? ""
        let candidate = row[kCGWindowLayer as String] as? Int ?? 0
        return owner == "Dock" && name.hasPrefix("Wallpaper-") && candidate < 0
            ? candidate
            : nil
    }.max() ?? Int.min
    let finderDesktopLayer = rows.compactMap { row -> Int? in
        let owner = row[kCGWindowOwnerName as String] as? String ?? ""
        let candidate = row[kCGWindowLayer as String] as? Int ?? 0
        return owner == "Finder" && candidate < 0 ? candidate : nil
    }.min() ?? Int.max
    let targetWindows = rows.filter { row in
        (row[kCGWindowOwnerPID as String] as? Int32) == targetPID
    }
    let wallpaperCandidates = targetWindows.filter { row in
        let candidate = row[kCGWindowLayer as String] as? Int ?? 0
        return candidate > dockWallpaperLayer && candidate < finderDesktopLayer
    }
    guard let wallpaper = wallpaperCandidates.first(where: { row in
        row[kCGWindowIsOnscreen as String] as? Bool ?? false
    }) ?? wallpaperCandidates.first else {
        fail("Amadeus wallpaper was not found between the Dock wallpaper and Finder desktop layers")
    }
    guard let canvas = targetWindows.first(where: { row in
        let candidate = row[kCGWindowLayer as String] as? Int ?? 0
        return candidate > finderDesktopLayer && candidate < 0
    }) else {
        fail("Amadeus interactive Canvas was not found above the Finder desktop layer")
    }

    let layer = wallpaper[kCGWindowLayer as String] as? Int ?? Int.min
    let onScreen = wallpaper[kCGWindowIsOnscreen as String] as? Bool ?? false
    let canvasLayer = canvas[kCGWindowLayer as String] as? Int ?? Int.min
    let canvasOnScreen = canvas[kCGWindowIsOnscreen as String] as? Bool ?? false

    guard onScreen else {
        fail("Amadeus wallpaper exists but CoreGraphics reports it off-screen")
    }
    guard layer > dockWallpaperLayer else {
        fail(
            "Amadeus wallpaper is hidden behind the Dock wallpaper: "
                + "layer=\(layer) dock_wallpaper_layer=\(dockWallpaperLayer)"
        )
    }
    guard layer < finderDesktopLayer else {
        fail(
            "Amadeus wallpaper can cover Finder desktop icons: "
                + "layer=\(layer) finder_desktop_layer=\(finderDesktopLayer)"
        )
    }
    guard canvasOnScreen else {
        fail("Amadeus interactive Canvas exists but CoreGraphics reports it off-screen")
    }
    print(
        "macOS window level ready: "
            + "wallpaper_layer=\(layer) dock_wallpaper_layer=\(dockWallpaperLayer) "
            + "finder_desktop_layer=\(finderDesktopLayer) canvas_layer=\(canvasLayer) "
            + "wallpaper_on_screen=true canvas_on_screen=true"
    )
}

main()
