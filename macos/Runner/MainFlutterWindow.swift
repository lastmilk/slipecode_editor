import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // 桌面 IDE 最小尺寸，避免布局被压扁
    self.minSize = NSSize(width: 1024, height: 680)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
