import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// 场景连接后 window.rootViewController 才可用，
  /// 此时兜底注册 AppDelegate 里的 MethodChannel（字体/背景选择器）。
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    (UIApplication.shared.delegate as? AppDelegate)?.configureChannelsIfPossible()
    // 冷启动经小组件 URL 打开：connectionOptions 里携带 URL
    connectionOptions.urlContexts.forEach {
      WidgetSync.shared.handleWidgetURL($0.url)
    }
  }

  /// 热路径：app 在后台/前台时点小组件按钮 → URL scheme 打开 app
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    URLContexts.forEach { WidgetSync.shared.handleWidgetURL($0.url) }
  }
}
