import CoreGraphics
import Foundation
// The window id of the app named on the command line (its display name:
// `sai` or `sai dev`, ADR 0019), so drive.sh can shoot one flavor while
// the other runs. No default: an unnamed lookup would find the daily copy.
guard CommandLine.arguments.count > 1 else {
  FileHandle.standardError.write("usage: wid.swift <display name>\n".data(using: .utf8)!)
  exit(2)
}
let owner = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w["kCGWindowOwnerName"] as? String) == owner && (w["kCGWindowLayer"] as? Int) == 0 {
  print(w["kCGWindowNumber"] as! Int); break
}
