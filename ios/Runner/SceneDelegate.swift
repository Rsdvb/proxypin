import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    /// App 已启动时收到的导入链接
    override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        super.scene(scene, openURLContexts: URLContexts)
        if let url = URLContexts.first?.url {
            ImportLinks.shared.receive(url.absoluteString)
        }
    }

    /// 由导入链接拉起 App 时，链接在启动参数里
    override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        if let url = connectionOptions.urlContexts.first?.url {
            ImportLinks.shared.receive(url.absoluteString)
        }
        if let item = connectionOptions.shortcutItem {
            ImportLinks.shared.receive(item.type)
        }
    }

    /// 长按图标的快捷操作。type 写在 Info.plist 里，就是控制连接的链接
    override func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        ImportLinks.shared.receive(shortcutItem.type)
        completionHandler(true)
    }

    @available(iOS 26.0, *)
    override func preferredWindowingControlStyle(for windowScene: UIWindowScene) -> UIWindowScene.WindowingControlStyle {
        return .minimal
    }
}
