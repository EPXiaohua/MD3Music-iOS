//
//  ImageSaverPlugin.swift
//  Runner
//
//  iOS 图片保存插件：MethodChannel "com.md3music.md3music/image_saver"，
//  对齐 Android 的 ImageSaverPlugin.kt。
//
//  分工与 Android 一致：Dart 侧先把图片下载到应用临时目录，再调
//  saveImage(path, fileName)，原生负责落盘——iOS 走 PHPhotoLibrary，
//  写入「MD3Music」相册。仅需 NSPhotoLibraryAddUsageDescription
//  （.addOnly 访问级别，不能读相册），权限弹窗由系统按需触发。
//
//  用 PHAssetCreationRequest + addResource(.photo) 而不是
//  creationRequestForAssetFromImage：前者按文件原样导入，
//  GIF/WebP 不会被 UIImage 解码压成静态图。
//
//  复制是重 IO，performChanges 在系统后台队列执行；结果统一回主线程
//  回调 Flutter。
//

import Flutter
import Photos
import UIKit

@objc class ImageSaverPlugin: NSObject {
  static let shared = ImageSaverPlugin()

  private let channelName = "com.md3music.md3music/image_saver"
  private let albumName = "MD3Music"

  private override init() {
    super.init()
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "saveImage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.handleSaveImage(call, result: result)
    }
  }

  // MARK: - 入口

  private func handleSaveImage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let path = args["path"] as? String, !path.isEmpty
    else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "path is required", details: nil))
      return
    }
    let src = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: src.path) else {
      result(FlutterError(code: "FILE_NOT_FOUND", message: "源文件不存在: \(path)", details: nil))
      return
    }

    // 权限检查：.addOnly 只申请"写入相册"，读不到用户已有照片。
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    switch status {
    case .authorized, .limited:
      saveToLibrary(at: src, result: result)
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] newStatus in
        DispatchQueue.main.async {
          if newStatus == .authorized || newStatus == .limited {
            self?.saveToLibrary(at: src, result: result)
          } else {
            result(FlutterError(
              code: "PERMISSION_DENIED", message: "缺少相册写入权限", details: nil))
          }
        }
      }
    default:
      result(FlutterError(code: "PERMISSION_DENIED", message: "缺少相册写入权限", details: nil))
    }
  }

  // MARK: - 落盘

  private func saveToLibrary(at src: URL, result: @escaping FlutterResult) {
    // 第一步：确保「MD3Music」相册存在（没有就建），记下 localIdentifier。
    ensureAlbum { [weak self] albumId in
      guard let self else { return }
      guard let albumId else {
        result(FlutterError(
          code: "SAVE_FAILED", message: "创建相册失败: \(self.albumName)", details: nil))
        return
      }
      self.importAsset(at: src, albumId: albumId, result: result)
    }
  }

  private func ensureAlbum(completion: @escaping (String?) -> Void) {
    if let existing = fetchAlbum()?.localIdentifier {
      completion(existing)
      return
    }
    var placeholder: PHObjectPlaceholder?
    PHPhotoLibrary.shared().performChanges({
      let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
        withTitle: self.albumName)
      placeholder = request.placeholderForCreatedAssetCollection
    }) { success, error in
      DispatchQueue.main.async {
        if success, let placeholder {
          completion(placeholder.localIdentifier)
        } else {
          NSLog("[ImageSaver] ensureAlbum failed: \(String(describing: error))")
          completion(nil)
        }
      }
    }
  }

  private func fetchAlbum() -> PHAssetCollection? {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "title == %@", albumName)
    return PHAssetCollection.fetchAssetCollections(
      with: .album, subtype: .albumRegular, options: options
    ).firstObject
  }

  private func importAsset(
    at src: URL, albumId: String, result: @escaping FlutterResult
  ) {
    guard let album = PHAssetCollection.fetchAssetCollections(
      withLocalIdentifiers: [albumId], options: nil
    ).firstObject else {
      result(FlutterError(code: "SAVE_FAILED", message: "目标相册不存在", details: nil))
      return
    }

    var assetPlaceholder: PHObjectPlaceholder?
    PHPhotoLibrary.shared().performChanges({
      let request = PHAssetCreationRequest.creationRequestForAsset()
      request.creationDate = Date()
      request.addResource(with: .photo, fileURL: src, options: nil)
      assetPlaceholder = request.placeholderForCreatedAsset
      if let placeholder = assetPlaceholder {
        PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
      }
    }) { success, error in
      DispatchQueue.main.async {
        if success, let placeholder = assetPlaceholder {
          NSLog("[ImageSaver] saved asset=\(placeholder.localIdentifier)")
          result(placeholder.localIdentifier)
        } else {
          NSLog("[ImageSaver] SAVE_FAILED: \(String(describing: error))")
          result(FlutterError(
            code: "SAVE_FAILED",
            message: error.map { "\($0.localizedDescription)" } ?? "写入相册失败",
            details: nil))
        }
      }
    }
  }
}
