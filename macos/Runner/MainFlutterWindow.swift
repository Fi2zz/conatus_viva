import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerFilePicker(flutterViewController)

    super.awakeFromNib()
  }

  /// WKWebView's `<input type="file">` is inert in this Flutter plugin (no
  /// `runOpenPanelWith` delegate), so the React page calls this channel and
  /// gets the selected bytes back as base64.
  private func registerFilePicker(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "viva/files",
      binaryMessenger: controller.engine.binaryMessenger
    )

    channel.setMethodCallHandler { call, result in
      guard call.method == "pickImages" else {
        result(FlutterMethodNotImplemented)
        return
      }

      let panel = NSOpenPanel()
      panel.allowsMultipleSelection = true
      panel.canChooseDirectories = false
      panel.canChooseFiles = true
      panel.allowedContentTypes = [.png, .jpeg, .webP]

      panel.begin { response in
        guard response == .OK else {
          result([Any]())
          return
        }

        var picked: [[String: String]] = []
        for url in panel.urls {
          guard let data = try? Data(contentsOf: url) else { continue }
          picked.append([
            "name": url.lastPathComponent,
            "mime": Self.mimeType(for: url),
            "base64": data.base64EncodedString(),
          ])
        }
        result(picked)
      }
    }
  }

  private static func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "png":
      return "image/png"
    case "jpg", "jpeg":
      return "image/jpeg"
    case "webp":
      return "image/webp"
    default:
      return "application/octet-stream"
    }
  }
}
