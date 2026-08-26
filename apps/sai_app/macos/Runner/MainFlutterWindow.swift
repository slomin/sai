import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

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
