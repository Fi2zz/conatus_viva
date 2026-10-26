import Cocoa
import FlutterMacOS
import Security
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerFilePicker(flutterViewController)
    registerSecrets(flutterViewController)

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

  /// Stores provider credentials in the login Keychain. Secrets never leave
  /// this function except as method-channel return values.
  private func registerSecrets(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "viva/secrets",
      binaryMessenger: controller.engine.binaryMessenger
    )

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "readAll":
        result(Self.readAllSecrets())
      case "writeAll":
        guard let values = call.arguments as? [String: String] else {
          result(FlutterError(
            code: "invalid_args",
            message: "expected a string map",
            details: nil
          ))
          return
        }
        do {
          try Self.writeAllSecrets(values)
          result(nil)
        } catch {
          result(FlutterError(
            code: "keychain",
            message: "Keychain write failed",
            details: nil
          ))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static let keychainService = "com.conatusviva.secrets"
  private static let keychainAccounts = [
    "DASHSCOPE_API_KEY",
    "DASHSCOPE_WORKSPACE_ID",
    "OSS_ACCESS_KEY_ID",
    "OSS_ACCESS_KEY_SECRET",
  ]

  private static func keychainQuery(account: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
    ]
  }

  private static func readAllSecrets() -> [String: String] {
    var out: [String: String] = [:]
    for account in keychainAccounts {
      var query = keychainQuery(account: account)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      guard status == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8) else {
        continue
      }
      out[account] = value
    }
    return out
  }

  private static func writeAllSecrets(_ values: [String: String]) throws {
    for account in keychainAccounts {
      let value = values[account] ?? ""
      if value.isEmpty {
        SecItemDelete(keychainQuery(account: account) as CFDictionary)
        continue
      }
      let data = Data(value.utf8)
      let updateStatus = SecItemUpdate(
        keychainQuery(account: account) as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      if updateStatus == errSecItemNotFound {
        var add = keychainQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
          throw NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(addStatus),
            userInfo: nil
          )
        }
      } else if updateStatus != errSecSuccess {
        throw NSError(
          domain: NSOSStatusErrorDomain,
          code: Int(updateStatus),
          userInfo: nil
        )
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
