import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var apnsChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AgentPilotApns")
    let channel = FlutterMethodChannel(
      name: "agentpilot/apns",
      binaryMessenger: registrar!.messenger()
    )
    apnsChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(FlutterError(code: "no_app", message: nil, details: nil)) }
      switch call.method {
      case "register":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
          DispatchQueue.main.async {
            if granted {
              UIApplication.shared.registerForRemoteNotifications()
            }
            result(granted)
          }
        }
      case "getToken":
        if let token = self.apnsToken {
          result(token)
        } else {
          result(FlutterError(code: "no_token", message: "APNs token 尚未就绪", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private var apnsToken: String?

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    apnsToken = token
    apnsChannel?.invokeMethod("onToken", arguments: token)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("APNs 注册失败: \(error.localizedDescription)")
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // App 前台时不弹横幅（应用内已有震动提醒），静默处理
    completionHandler([])
  }
}
