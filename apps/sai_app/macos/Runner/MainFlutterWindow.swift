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
    self.minSize = NSSize(width: 720, height: 520)
    _ = self.setFrameAutosaveName("sai.main")
    self.setFrameUsingName("sai.main")

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerAccessibility(flutterViewController)

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
}
