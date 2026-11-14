import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

  // Cold-started from a `dshgo://…` link or an opened file: the connection
  // options carry the URLs; hand them to the links bridge (it holds them
  // until Dart's `ready` — see DshLinksBridge).
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    for context in connectionOptions.urlContexts {
      DshLinksBridge.shared.handleOpen(context.url)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  // Warmed app opened with a link (browser, Files' 「共享」…).
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      DshLinksBridge.shared.handleOpen(context.url)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }
}
