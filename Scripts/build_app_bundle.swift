import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dist = root.appendingPathComponent("dist", isDirectory: true)
let scratch = root.appendingPathComponent(".build-app", isDirectory: true)
let app = dist.appendingPathComponent("Dock Click Minimizer.app", isDirectory: true)
let contents = app.appendingPathComponent("Contents", isDirectory: true)
let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
let resources = contents.appendingPathComponent("Resources", isDirectory: true)
let executable = macOS.appendingPathComponent("dock-click-minimizer")
let icon = resources.appendingPathComponent("AppIcon.icns")
let buildStartedAt = Date()

@discardableResult
func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()

    guard allowFailure || process.terminationStatus == 0 else {
        fatalError("\(executable) failed with status \(process.terminationStatus)")
    }

    return process.terminationStatus
}

try? FileManager.default.removeItem(at: scratch)
let buildStatus = try run("/usr/bin/swift", ["build", "--scratch-path", scratch.path, "-c", "release"], allowFailure: true)
let builtExecutable = scratch.appendingPathComponent("release/dock-click-minimizer")
guard FileManager.default.fileExists(atPath: builtExecutable.path) else {
    fatalError("/usr/bin/swift failed with status \(buildStatus), and no release executable was produced")
}
let attributes = try FileManager.default.attributesOfItem(atPath: builtExecutable.path)
if let modifiedAt = attributes[.modificationDate] as? Date,
   modifiedAt < buildStartedAt {
    fatalError("/usr/bin/swift failed with status \(buildStatus), and the release executable was not refreshed")
}

try? FileManager.default.removeItem(at: app)
try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

try FileManager.default.copyItem(at: builtExecutable, to: executable)
try FileManager.default.copyItem(at: root.appendingPathComponent("Assets/AppIcon.icns"), to: icon)

let infoPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>dock-click-minimizer</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex.dock-click-minimizer</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Dock Click Minimizer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
"""

try infoPlist.write(
    to: contents.appendingPathComponent("Info.plist"),
    atomically: true,
    encoding: .utf8
)

try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])

print("Built \(app.path)")
