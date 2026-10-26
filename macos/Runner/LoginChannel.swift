import Cocoa
import FlutterMacOS
import WebKit

/// macOS 原生番茄登录窗口：对齐 third_party webview_windows fork 的行为
/// （域名白名单、禁弹窗、读取书架 Cookie）。仅与 fanqienovel.com 相关。
final class LoginChannel: NSObject {
  static let allowedHosts = [
    "fanqienovel.com", "snssdk.com", "bytedance.com", "zijieapi.com",
  ]
  private static var controller: LoginWindowController?

  static func register(with flutterController: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "fqapp/macos_login",
      binaryMessenger: flutterController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      DispatchQueue.main.async {
        switch call.method {
        case "login":
          showLogin(result)
        case "cancelLogin":
          // 关窗会触发 windowWillClose → finish(nil) → result(nil)；
          // 没有窗口时直接回 nil，避免 Dart 侧 Future 悬挂。
          if let loginWindow = controller {
            loginWindow.window?.close()
          } else {
            result(nil)
          }
        case "clearSession":
          clearSession { result(nil) }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  static func isAllowedHost(_ host: String?) -> Bool {
    guard let host else { return false }
    return allowedHosts.contains { root in
      host == root || host.hasSuffix(".\(root)")
    }
  }

  private static func showLogin(_ result: @escaping FlutterResult) {
    if let existing = controller {
      // 已有登录窗时不能丢弃新的 FlutterResult：把旧窗的 finish 链换绑到
      // 本次调用，避免旧窗关闭时 Dart 侧 Future 悬挂。
      existing.onFinish = { cookies in
        DispatchQueue.main.async { result(cookies) }
      }
      existing.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false
    )
    window.title = "番茄官方登录 · 只读导入"
    window.center()

    let webView = WKWebView(frame: .zero)
    webView.navigationDelegate = LoginNavigationDelegate.shared
    webView.uiDelegate = LoginUIDelegate.shared

    let hint = NSTextField(
      wrappingLabelWithString:
        "请在番茄官方网页完成登录和验证，再点击「读取书架」。账号只用于读取。"
    )
    hint.isEditable = false
    hint.font = NSFont.systemFont(ofSize: 13)

    let readButton = NSButton(title: "读取书架", target: nil, action: nil)
    readButton.bezelStyle = .rounded
    readButton.keyEquivalent = "\r"

    let cancelButton = NSButton(title: "关闭", target: nil, action: nil)
    cancelButton.bezelStyle = .rounded

    let bar = NSStackView(views: [hint, readButton, cancelButton])
    bar.orientation = .horizontal
    bar.alignment = .centerY
    bar.spacing = 12
    bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
    readButton.setContentHuggingPriority(.required, for: .horizontal)
    cancelButton.setContentHuggingPriority(.required, for: .horizontal)

    let root = NSView()
    root.addSubview(webView)
    root.addSubview(bar)
    webView.translatesAutoresizingMaskIntoConstraints = false
    bar.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: root.topAnchor),
      webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      bar.topAnchor.constraint(equalTo: webView.bottomAnchor),
      bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      bar.heightAnchor.constraint(equalToConstant: 56),
    ])
    window.contentView = root

    let windowController = LoginWindowController(window: window)
    window.delegate = windowController
    controller = windowController

    let finish: (String?) -> Void = { cookies in
      DispatchQueue.main.async {
        guard LoginChannel.controller === windowController else { return }
        LoginChannel.controller = nil
        windowController.onFinish = nil
        window.close()
        result(cookies)
      }
    }
    windowController.onFinish = finish
    readButton.target = windowController
    readButton.action = #selector(LoginWindowController.readCookies(_:))
    cancelButton.target = windowController
    cancelButton.action = #selector(LoginWindowController.cancel(_:))

    var request = URLRequest(
      url: URL(string: "https://fanqienovel.com/main/writer/login")!
    )
    request.cachePolicy = .reloadIgnoringLocalCacheData
    webView.load(request)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private static func clearSession(_ done: @escaping () -> Void) {
    // WKWebsiteDataStore.default() 与登录窗用的同一个 store（登录窗未显式
    // 指定非持久化 store），清番茄域 Cookie 即可；其余域名一律不动。
    let store = WKWebsiteDataStore.default()
    store.httpCookieStore.getAllCookies { cookies in
      let group = DispatchGroup()
      for cookie in cookies {
        let domain = cookie.domain.hasPrefix(".")
          ? String(cookie.domain.dropFirst()) : cookie.domain
        guard isAllowedHost(domain) else { continue }
        group.enter()
        store.httpCookieStore.delete(cookie) { group.leave() }
      }
      group.notify(queue: .main) { done() }
    }
  }

  /// 「读取书架」：抓取番茄域 Cookie 并拼成 Cookie 头，校验逻辑与 Windows
  /// fork 的 getFanqieCookies 一致（sessionid / sessionid_ss / sid_tt）。
  static func collectCookies(_ done: @escaping (String?) -> Void) {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      let fanqie = cookies.filter { cookie in
        let domain = cookie.domain.hasPrefix(".")
          ? String(cookie.domain.dropFirst()) : cookie.domain
        return domain == "fanqienovel.com"
          || domain.hasSuffix(".fanqienovel.com")
      }
      let required = ["sessionid", "sessionid_ss", "sid_tt"]
      let hasLogin = fanqie.contains {
        required.contains($0.name) && !$0.value.isEmpty
      }
      guard hasLogin else { done(nil); return }
      let header = fanqie.map { "\($0.name)=\($0.value)" }
        .joined(separator: "; ")
      done(header.count > 12 * 1024 ? nil : header)
    }
  }
}

final class LoginWindowController: NSWindowController, NSWindowDelegate {
  var onFinish: ((String?) -> Void)?

  /// 结果只经 finish 回传一次；之后置空防止 windowWillClose 重复回调。
  private func finishOnce(_ cookies: String?) {
    let finish = onFinish
    onFinish = nil
    finish?(cookies)
  }

  @objc func readCookies(_ sender: Any?) {
    LoginChannel.collectCookies { [weak self] header in
      DispatchQueue.main.async { self?.finishOnce(header) }
    }
  }

  @objc func cancel(_ sender: Any?) {
    finishOnce(nil)
  }

  func windowWillClose(_ notification: Notification) {
    finishOnce(nil)
  }
}

final class LoginNavigationDelegate: NSObject, WKNavigationDelegate {
  static let shared = LoginNavigationDelegate()

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if let url = navigationAction.request.url, LoginChannel.isAllowedHost(url.host) {
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
    }
  }

  // 对齐 WebviewPopupWindowPolicy.deny：不允许 window.open 弹出新窗口。
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? { nil }
}

final class LoginUIDelegate: NSObject, WKUIDelegate {
  static let shared = LoginUIDelegate()

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping () -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.runModal()
    completionHandler()
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "确定")
    alert.addButton(withTitle: "取消")
    completionHandler(alert.runModal() == .alertFirstButtonReturn)
  }
}
