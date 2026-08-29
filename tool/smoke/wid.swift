import CoreGraphics
import Foundation
// The window id of the app named on the command line (its display name:
// `sai` or `sai dev`, ADR 0019), so drive.sh can shoot one flavor while
// the other runs.
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sai"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == owner && (w["kCGWindowLayer"] as? Int) == 0 {
  print(w["kCGWindowNumber"] as! Int); break
}
