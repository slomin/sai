import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // Where the window was left (#76, ADR 0015): AppKit keeps the frame
    // under this name in the app's defaults and clamps a restored frame
    // to the screens that exist; a floor keeps the sidebar on screen.
    // The dev flavor (ADR 0019) names its frame apart from stable's, so
    // the two windows come back where each was left.
    let flavor = Bundle.main.infoDictionary?["SaiFlavor"] as? String
    let frameName = flavor == "dev" ? "sai-dev.main" : "sai.main"
    self.minSize = NSSize(width: 720, height: 520)
    _ = self.setFrameAutosaveName(frameName)
    self.setFrameUsingName(frameName)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerAccessibility(flutterViewController)
    registerFinder(flutterViewController)

    super.awakeFromNib()
  }

  /// `sai/accessibility`: macOS Reduce Motion for the app's motion policy.
  /// The engine forwards the flag on iOS only, so the app asks here and is
  /// told when System Settings flips it.
  private func registerAccessibility(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "sai/accessibility", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "reduceMotion":
        result(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { _ in
      channel.invokeMethod(
        "reduceMotionChanged",
        arguments: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
  }

  /// `sai/finder` (#40): the two Finder gestures Settings needs. `reveal`
  /// selects a path in a Finder window; `chooseFile` puts up an open
  /// panel for one file and answers its path, or nothing when cancelled.
  /// The app never spawns `open`: the Runner owns the panels.
  private func registerFinder(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "sai/finder", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "reveal":
        guard let path = call.arguments as? String else {
          result(FlutterError(code: "argument", message: "reveal takes a path", details: nil))
          return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        result(true)
      case "chooseFile":
        let arguments = call.arguments as? [String: Any]
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = arguments?["prompt"] as? String ?? "Choose a file"
        let respond: (NSApplication.ModalResponse) -> Void = { response in
          result(response == .OK ? panel.url?.path : nil)
        }
        if let window = self {
          panel.beginSheetModal(for: window, completionHandler: respond)
        } else {
          respond(panel.runModal())
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
