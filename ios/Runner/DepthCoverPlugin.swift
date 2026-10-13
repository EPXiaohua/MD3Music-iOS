// DepthCoverPlugin.swift — iOS 3D 封面（Depth Anything V2 ViT-S 推理 + push-pull 修补
// + MI-GAN 神经修补 + 三层视差切割），与 Android DepthCoverPlugin.kt 完全对齐。
//
// 编译条件：整个文件包在 `#if DEPTH_3D_LINKED` 内 —— 标准包（不定义该宏）此文件
// 为空翻译单元、零体积零依赖；3D 包由 CI 写入链接 xcconfig（-lonnxruntime +
// -DDEPTH_3D_LINKED）后参与编译。
//
// ORT C API 采用「自声明函数表」方式绑定：不引入 C 头文件，直接按
// onnxruntime_c_api.h（v1.22.0）的 OrtApi 结构体前 110 个字段顺序声明
// （@since 单调性校验过，v1.0 起冻结不变）。未用字段以同尺寸占位类型填充，
// 保证内存布局与 C 结构体一致。经 OrtGetApiBase().GetApi(22) 获取。
//
// 通道 "com.md3music.md3music/depth_cover"，方法与 Android 一致：
// - isModelLoaded / isInpaintModelLoaded -> Bool
// - loadModel(modelAsset?) -> Bool | error("LOAD_FAILED")
// - loadInpaintModel() -> Bool | error("LOAD_FAILED")
// - generate(sourcePath, outDir, key) -> {layers:[3 路径]} | null(同 key 在途)
// - generateDepth(sourcePath, outDir, key) -> {depth, depthStd, bgFill, inpaint}
// - showToast(message) -> iOS 无系统 toast，仅记日志
#if DEPTH_3D_LINKED

import Foundation
import CoreGraphics
import ImageIO
import Flutter

// MARK: - ORT C API 最小绑定

@_silgen_name("OrtGetApiBase")
func OrtGetApiBase() -> UnsafePointer<OrtApiBase>?

struct OrtApiBase {
  // GetApi 返回 UnsafeRawPointer（C 函数指针类型不能携带 Swift struct 指针，
  // 需在使用点 assumingMemoryBound 重新绑定到 OrtApi）。
  let GetApi: @convention(c) (UInt32) -> UnsafeRawPointer?
  let GetVersionString: @convention(c) () -> UnsafePointer<CChar>?
}

/// 未使用的 OrtApi 字段占位类型（所有字段均为函数指针，8 字节，布局不变）。
/// 注意：不能声明为 private —— OrtApi（internal）的属性引用 private 类型
/// 会触发 "Property must be declared fileprivate" 编译错误。
typealias OrtFn = @convention(c) () -> OpaquePointer?

/// OrtApi v1.22 前缀（字段 1..110，顺序与 onnxruntime_c_api.h 逐字段一致）。
/// 1-3 Status / 4-7 Env / 8-11 Session+Run / 12-26 SessionOptions /
/// 27-39 CustomOp+SessionInfo / 40-48 RunOptions / 49-70 Tensor /
/// 71-92 MemoryInfo+Allocator+Kernel / 93-102 Release / 103-110 Denotation+Map/Sequence。
struct OrtApi {
  // 1
  let CreateStatus: @convention(c) (Int32, UnsafePointer<CChar>?) -> OpaquePointer?
  // 2
  let GetErrorCode: OrtFn
  // 3
  let GetErrorMessage: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
  // 4
  let CreateEnv: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
  // 5-7
  let CreateEnvWithCustomLogger: OrtFn
  let EnableTelemetryEvents: OrtFn
  let DisableTelemetryEvents: OrtFn
  // 8
  let CreateSession: OrtFn
  // 9
  let CreateSessionFromArray: @convention(c) (OpaquePointer?, UnsafeRawPointer?, Int, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
  // 10
  let Run: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<OpaquePointer?>?, Int, UnsafePointer<UnsafePointer<CChar>?>?, Int, UnsafeMutablePointer<OpaquePointer?>?) -> OpaquePointer?
  // 11
  let CreateSessionOptions: @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
  // 12-23
  let SetOptimizedModelFilePath: OrtFn
  let CloneSessionOptions: OrtFn
  let SetSessionExecutionMode: OrtFn
  let EnableProfiling: OrtFn
  let DisableProfiling: OrtFn
  let EnableMemPattern: OrtFn
  let DisableMemPattern: OrtFn
  let EnableCpuMemArena: OrtFn
  let DisableCpuMemArena: OrtFn
  let SetSessionLogId: OrtFn
  let SetSessionLogVerbosityLevel: OrtFn
  let SetSessionLogSeverityLevel: OrtFn
  // 24
  let SetSessionGraphOptimizationLevel: @convention(c) (OpaquePointer?, Int32) -> OpaquePointer?
  // 25
  let SetIntraOpNumThreads: @convention(c) (OpaquePointer?, Int32) -> OpaquePointer?
  // 26-30
  let SetInterOpNumThreads: OrtFn
  let CreateCustomOpDomain: OrtFn
  let CustomOpDomain_Add: OrtFn
  let AddCustomOpDomain: OrtFn
  let RegisterCustomOpsLibrary: OrtFn
  // 31-33
  let SessionGetInputCount: @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int>) -> OpaquePointer?
  let SessionGetOutputCount: @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int>) -> OpaquePointer?
  let SessionGetOverridableInitializerCount: OrtFn
  // 34-36
  let SessionGetInputTypeInfo: @convention(c) (OpaquePointer?, Int, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
  let SessionGetOutputTypeInfo: @convention(c) (OpaquePointer?, Int, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
  let SessionGetOverridableInitializerTypeInfo: OrtFn
  // 37-39
  // 37/38：签名含 allocator（ORT 1.15+，第 3 参数 OrtAllocator*，第 4 参数 char** out）
  // —— 旧 3 参数签名会导致 ORT 内部解引用垃圾 allocator → SIGBUS
  let SessionGetInputName: @convention(c) (OpaquePointer?, Int, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> OpaquePointer?
  let SessionGetOutputName: @convention(c) (OpaquePointer?, Int, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> OpaquePointer?
  let SessionGetOverridableInitializerName: OrtFn
  // 40-48 RunOptions
  let CreateRunOptions: OrtFn
  let RunOptionsSetRunLogVerbosityLevel: OrtFn
  let RunOptionsSetRunLogSeverityLevel: OrtFn
  let RunOptionsSetRunTag: OrtFn
  let RunOptionsGetRunLogVerbosityLevel: OrtFn
  let RunOptionsGetRunLogSeverityLevel: OrtFn
  let RunOptionsGetRunTag: OrtFn
  let RunOptionsSetTerminate: OrtFn
  let RunOptionsUnsetTerminate: OrtFn
  // 49
  let CreateTensorAsOrtValue: OrtFn
  // 50
  let CreateTensorWithDataAsOrtValue: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int, UnsafePointer<Int64>?, Int, Int32, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
  // 51
  let IsTensor: OrtFn
  // 52
  let GetTensorMutableData: @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> OpaquePointer?
  // 53-55
  let FillStringTensor: OrtFn
  let GetStringTensorDataLength: OrtFn
  let GetStringTensorContent: OrtFn
  // 56
  let CastTypeInfoToTensorInfo: @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
  // 57-60
  let GetOnnxTypeFromTypeInfo: OrtFn
  let CreateTensorTypeAndShapeInfo: OrtFn
  let SetTensorElementType: OrtFn
  let SetDimensions: OrtFn
  // 61
  let GetTensorElementType: @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>) -> OpaquePointer?
  // 62
  let GetDimensionsCount: @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int>) -> OpaquePointer?
  // 63
  let GetDimensions: @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int64>?, Int) -> OpaquePointer?
  // 64
  let GetSymbolicDimensions: OrtFn
  // 65
  let GetTensorShapeElementCount: @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int>) -> OpaquePointer?
  // 66
  let GetTensorTypeAndShape: @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
  // 67-70
  let GetTypeInfo: OrtFn
  let GetValueType: OrtFn
  let CreateMemoryInfo: OrtFn
  let CreateCpuMemoryInfo: @convention(c) (Int32, Int32, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
  // 71-75
  let CompareMemoryInfo: OrtFn
  let MemoryInfoGetName: OrtFn
  let MemoryInfoGetId: OrtFn
  let MemoryInfoGetMemType: OrtFn
  let MemoryInfoGetType: OrtFn
  // 76-78
  let AllocatorAlloc: OrtFn
  // C 实际签名是 void AllocatorFree(OrtAllocator*, void*)，返回类型必须为 Void
  let AllocatorFree: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
  let AllocatorGetInfo: OrtFn
  // 79
  let GetAllocatorWithDefaultOptions: @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
  // 80-92
  let AddFreeDimensionOverride: OrtFn
  let GetValue: OrtFn
  let GetValueCount: OrtFn
  let CreateValue: OrtFn
  let CreateOpaqueValue: OrtFn
  let GetOpaqueValue: OrtFn
  let KernelInfoGetAttribute_float: OrtFn
  let KernelInfoGetAttribute_int64: OrtFn
  let KernelInfoGetAttribute_string: OrtFn
  let KernelContext_GetInputCount: OrtFn
  let KernelContext_GetOutputCount: OrtFn
  let KernelContext_GetInput: OrtFn
  let KernelContext_GetOutput: OrtFn
  // 93-102 Release 系列（void 返回）
  let ReleaseEnv: @convention(c) (OpaquePointer?) -> Void
  let ReleaseStatus: @convention(c) (OpaquePointer?) -> Void
  let ReleaseMemoryInfo: @convention(c) (OpaquePointer?) -> Void
  let ReleaseSession: @convention(c) (OpaquePointer?) -> Void
  let ReleaseValue: @convention(c) (OpaquePointer?) -> Void
  let ReleaseRunOptions: @convention(c) (OpaquePointer?) -> Void
  let ReleaseTypeInfo: @convention(c) (OpaquePointer?) -> Void
  let ReleaseTensorTypeAndShapeInfo: @convention(c) (OpaquePointer?) -> Void
  let ReleaseSessionOptions: @convention(c) (OpaquePointer?) -> Void
  let ReleaseCustomOpDomain: @convention(c) (OpaquePointer?) -> Void
  // 103-110 Denotation + Map/Sequence TypeInfo（1.30 头文件逐字段核对；
  // 此前误写为 Release 系列，与真实函数表错位 8 槽）
  let GetDenotationFromTypeInfo: OrtFn
  let CastTypeInfoToMapTypeInfo: OrtFn
  let CastTypeInfoToSequenceTypeInfo: OrtFn
  let GetMapKeyType: OrtFn
  let GetMapValueType: OrtFn
  let GetSequenceElementType: OrtFn
  let ReleaseMapTypeInfo: OrtFn
  let ReleaseSequenceTypeInfo: OrtFn
}

/// ORT 常量（onnxruntime_c_api.h v1.22.0 逐一核对）
private enum Ort {
  /// OrtLoggingLevel.ORT_LOGGING_LEVEL_WARNING
  static let loggingWarning: Int32 = 2
  /// GraphOptimizationLevel.ORT_DISABLE_ALL —— 对齐 Android NO_OPT：
  /// q4f16/int8 裁剪模型缺融合内核，开优化会生成 contrib 节点 → Kernel not found
  static let disableAll: Int32 = 0
  /// ONNXTensorElementDataType.FLOAT
  static let typeFloat: Int32 = 1
  /// ONNXTensorElementDataType.UINT8
  static let typeUint8: Int32 = 2
  /// OrtAllocatorType.OrtArenaAllocator
  static let arenaAllocator: Int32 = 1
  /// OrtMemType.OrtMemTypeDefault
  static let memTypeDefault: Int32 = 0
  // 必须与 CI 打包的 ORT 静态库版本一致（ios-build.yml 下载 onnxruntime-c-1.30.0）。
  // 上游 Android 也用 1.30.0（自编 reduced-ops AAR）；OrtApi 只增不改，
  // 前 110 字段声明对所有 >=1.22 版本有效，升版只需改此常量。
  static let apiVersion: UInt32 = 30
}

private enum DepthError: Error, CustomStringConvertible {
  case ort(String)
  case failed(String)

  var description: String {
    switch self {
    case .ort(let m): return m
    case .failed(let m): return m
    }
  }
}

// MARK: - 修补工具（对齐 InpaintTools.kt）

/// 3D 封面背景修补工具集：joint bilateral 保边深度平滑 + smoothstep 前景掩码 +
/// 分离式 max filter 掩码膨胀。全部作用在 D×D 深度网格上。
private enum InpaintTools {

  /// 联合双边滤波平滑深度图。radius=2（5×5 窗），sigmaS 按像素距离、
  /// sigmaC 按引导亮度差（0..1）。输出新数组，不改输入。
  static func jointBilateralSmooth(
    _ norm: [Float], _ guide: [Float], _ d: Int,
    radius: Int = 2, sigmaS: Float = 1.4, sigmaC: Float = 0.12
  ) -> [Float] {
    var out = [Float](repeating: 0, count: norm.count)
    let inv2s2 = 1.0 / (2.0 * sigmaS * sigmaS)
    let inv2c2 = 1.0 / (2.0 * sigmaC * sigmaC)
    for y in 0..<d {
      for x in 0..<d {
        let i = y * d + x
        let c0 = guide[i]
        var wSum: Float = 0
        var acc: Float = 0
        for dy in -radius...radius {
          let yy = min(max(y + dy, 0), d - 1)
          for dx in -radius...radius {
            let xx = min(max(x + dx, 0), d - 1)
            let j = yy * d + xx
            let ds = Float(dx * dx + dy * dy) * inv2s2
            let dc = (guide[j] - c0) * (guide[j] - c0) * inv2c2
            let w = exp(-(ds + dc))
            acc += w * norm[j]
            wSum += w
          }
        }
        out[i] = acc / wSum
      }
    }
    return out
  }

  static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
  }

  /// 前景掩码：深度 >= lo 渐入，>= hi 全前景（1=主体/洞，0=背景）。
  static func fgMask(_ norm: [Float], d: Int, lo: Float = 0.55, hi: Float = 0.65) -> [Float] {
    var out = [Float](repeating: 0, count: norm.count)
    for i in 0..<norm.count { out[i] = smoothstep(lo, hi, norm[i]) }
    return out
  }

  /// 掩码膨胀（分离式 max filter：水平一趟 + 垂直一趟，等价方形结构元）。
  /// 洞向外扩 radius 像素，把主体过渡带吞进洞里，使填充源只来自纯净背景。
  static func dilateHole(_ mask: [Float], d: Int, radius: Int) -> [Float] {
    var tmp = [Float](repeating: 0, count: mask.count)
    for y in 0..<d {
      let row = y * d
      for x in 0..<d {
        var m: Float = 0
        for dx in -radius...radius {
          let xx = min(max(x + dx, 0), d - 1)
          m = max(m, mask[row + xx])
        }
        tmp[row + x] = m
      }
    }
    var out = [Float](repeating: 0, count: mask.count)
    for y in 0..<d {
      for x in 0..<d {
        var m: Float = 0
        for dy in -radius...radius {
          let yy = min(max(y + dy, 0), d - 1)
          m = max(m, tmp[yy * d + x])
        }
        out[y * d + x] = m
      }
    }
    return out
  }
}

// MARK: - Push-Pull 金字塔修补（对齐 PullPushFiller.kt）

/// Push-Pull 金字塔插值修补（Gortler et al. 2006）。输入 RGBA8 像素 + 洞掩码
/// （1=洞），输出修补后整幅背景图（非洞像素原样保留）。
private enum PullPushFiller {

  private final class Level {
    let w: Int, h: Int
    var r: [Float], g: [Float], b: [Float], wt: [Float]
    init(_ w: Int, _ h: Int) {
      self.w = w; self.h = h
      let n = w * h
      r = [Float](repeating: 0, count: n)
      g = [Float](repeating: 0, count: n)
      b = [Float](repeating: 0, count: n)
      wt = [Float](repeating: 0, count: n)
    }
  }

  /// mask[i] ∈ 0..1 洞概率（≥0.5 完全洞权重 0，羽化边缘线性降权）。
  static func fill(_ pixels: [UInt8], _ w: Int, _ h: Int, _ mask: [Float]) -> [UInt8] {
    // 1) 镜像 pad 8px：让边缘也用真实背景填充（防边缘条带）
    let pad = 8
    let pw = w + 2 * pad
    let ph = h + 2 * pad
    var pPix = [UInt8](repeating: 0, count: pw * ph * 4)
    var pMask = [Float](repeating: 0, count: pw * ph)
    for y in 0..<ph {
      let sy = mirror(y - pad, h)
      for x in 0..<pw {
        let sx = mirror(x - pad, w)
        let si = (sy * w + sx) * 4
        let di = (y * pw + x) * 4
        pPix[di] = pixels[si]
        pPix[di + 1] = pixels[si + 1]
        pPix[di + 2] = pixels[si + 2]
        pPix[di + 3] = pixels[si + 3]
        pMask[y * pw + x] = mask[sy * w + sx]
      }
    }
    // 2) Pull：逐层 2x 降采样，洞像素权重 0
    var levels: [Level] = [toLevel(pPix, pMask, pw, ph)]
    while levels.last!.w > 1 || levels.last!.h > 1 {
      let up = levels.last!
      let nw = (up.w + 1) / 2
      let nh = (up.h + 1) / 2
      let lo = Level(nw, nh)
      for y in 0..<nh {
        for x in 0..<nw {
          var r: Float = 0, g: Float = 0, b: Float = 0, ws: Float = 0
          for dy in 0...1 {
            for dx in 0...1 {
              let ux = min(x * 2 + dx, up.w - 1)
              let uy = min(y * 2 + dy, up.h - 1)
              let ui = uy * up.w + ux
              let wgt = up.wt[ui]
              r += up.r[ui] * wgt
              g += up.g[ui] * wgt
              b += up.b[ui] * wgt
              ws += wgt
            }
          }
          let li = y * nw + x
          if ws > 1e-6 {
            lo.r[li] = r / ws
            lo.g[li] = g / ws
            lo.b[li] = b / ws
          }
          lo.wt[li] = ws / 4
        }
      }
      levels.append(lo)
    }
    // 3) Push：自顶向下回填洞像素（双线性插值上层），非洞像素保持原样
    for li in stride(from: levels.count - 2, through: 0, by: -1) {
      let lo = levels[li]
      let up = levels[li + 1]
      let isBase = li == 0
      for y in 0..<lo.h {
        for x in 0..<lo.w {
          let i = y * lo.w + x
          let keep = lo.wt[i]
          // 非底层：只回填完全洞（羽化像素在下采样层保持原值，避免漂移）
          if keep >= 1 - 1e-6 || (!isBase && keep > 1e-6) { continue }
          // 上层坐标（双线性）
          let fx = (Float(x) - 0.5) / 2
          let fy = (Float(y) - 0.5) / 2
          let x0 = min(max(Int(fx), 0), up.w - 1)
          let y0 = min(max(Int(fy), 0), up.h - 1)
          let x1 = min(x0 + 1, up.w - 1)
          let y1 = min(y0 + 1, up.h - 1)
          let tx = min(max(fx - Float(x0), 0), 1)
          let ty = min(max(fy - Float(y0), 0), 1)
          let i00 = y0 * up.w + x0, i01 = y0 * up.w + x1
          let i10 = y1 * up.w + x0, i11 = y1 * up.w + x1
          func pick(_ arr: [Float]) -> Float {
            arr[i00] * (1 - tx) * (1 - ty) + arr[i01] * tx * (1 - ty)
              + arr[i10] * (1 - tx) * ty + arr[i11] * tx * ty
          }
          let pr = pick(up.r), pg = pick(up.g), pb = pick(up.b)
          if isBase && keep > 1e-6 {
            // 底层羽化像素：原色与填充色按 keep 混合，消除轮廓硬边环
            lo.r[i] = lo.r[i] * keep + pr * (1 - keep)
            lo.g[i] = lo.g[i] * keep + pg * (1 - keep)
            lo.b[i] = lo.b[i] * keep + pb * (1 - keep)
          } else {
            lo.r[i] = pr
            lo.g[i] = pg
            lo.b[i] = pb
          }
          // 继承上层有效权重（>0 即可继续下传）
          lo.wt[i] = up.wt[i00]
        }
      }
    }
    // 4) 裁回原尺寸输出（alpha 沿用原图）
    let base = levels[0]
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
      for x in 0..<w {
        let bi = (y + pad) * pw + (x + pad)
        let di = (y * w + x) * 4
        out[di] = UInt8(min(max(Int(base.r[bi]), 0), 255))
        out[di + 1] = UInt8(min(max(Int(base.g[bi]), 0), 255))
        out[di + 2] = UInt8(min(max(Int(base.b[bi]), 0), 255))
        out[di + 3] = pixels[di + 3]
      }
    }
    return out
  }

  private static func toLevel(_ pix: [UInt8], _ mask: [Float], _ w: Int, _ h: Int) -> Level {
    let lv = Level(w, h)
    for i in 0..<(w * h) {
      let hole = mask[i]
      // 洞概率 >=0.5 → 权重 0；羽化区线性降权
      let keep = min(max((0.5 - hole) * 2, 0), 1)
      let pi = i * 4
      lv.r[i] = Float(pix[pi])
      lv.g[i] = Float(pix[pi + 1])
      lv.b[i] = Float(pix[pi + 2])
      lv.wt[i] = keep
    }
    return lv
  }

  /// 镜像坐标折返（-1 → 0，w → w-1）。
  private static func mirror(_ v: Int, _ size: Int) -> Int {
    var x = v
    if x < 0 { x = -x - 1 }
    if x >= size { x = 2 * size - x - 1 }
    return min(max(x, 0), size - 1)
  }
}

// MARK: - 插件主体

@objc final class DepthCoverPlugin: NSObject {

  static let shared = DepthCoverPlugin()

  private static let channelName = "com.md3music.md3music/depth_cover"

  /// 深度推理网格（ViT patch=14 对齐；与 Android DEPTH_SIZE 一致）
  private static let depthSize = 378
  /// 背景修补掩码膨胀半径（@深度网格）
  private static let maskDilateRadius = 4
  /// ImageNet 归一化（与 fabio-sim/Depth-Anything-ONNX infer.py 一致）
  private static let mean: [Float] = [0.485, 0.456, 0.406]
  private static let std: [Float] = [0.229, 0.224, 0.225]
  /// 深度带（0=远/背景, 1=近/前景），相邻带重叠 + 羽化避免硬边
  private static let bands: [(Float, Float)] = [(0.00, 0.40), (0.35, 0.70), (0.65, 1.00)]
  private static let feather: Float = 0.10
  /// 模型资产名（CI 注入 Runner.app/models/）
  private static let depthModelName = "depth_anything_v2_vits_q4f16"
  private static let inpaintModelName = "migan512_pipeline_int8"

  private let queue = DispatchQueue(label: "com.md3music.depth_cover", qos: .userInitiated)
  private let lock = NSLock()
  private var inFlight = Set<String>()

  private var api: UnsafePointer<OrtApi>?
  private var env: OpaquePointer?
  private var memInfo: OpaquePointer?
  private var allocator: OpaquePointer?
  private var session: OpaquePointer?
  private var inpaintSession: OpaquePointer?
  // CreateSessionFromArray 零拷贝引用模型 buffer，必须与会话同生命周期保活，
  // 否则首次 Run 读权重时访问悬垂内存（SIGBUS）
  private var depthModelData: Data?
  private var inpaintModelData: Data?
  private var channelsAttached = false

  private override init() {
    super.init()
  }

  // MARK: 注册（对齐 AppDelegate.configureChannelsIfPossible 模式，幂等）

  func attach(messenger: FlutterBinaryMessenger) {
    guard !channelsAttached else { return }
    channelsAttached = true
    FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }
    if let ver = ortVersionString() {
      NSLog("[DepthCover] plugin attached (onnxruntime %@)", ver)
    } else {
      NSLog("[DepthCover] plugin attached")
    }
  }

  private func ortVersionString() -> String? {
    guard let base = OrtGetApiBase(), let c = base.pointee.GetVersionString() else { return nil }
    return String(cString: c)
  }

  // MARK: 方法分发

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isModelLoaded":
      result(session != nil)
    case "isInpaintModelLoaded":
      result(inpaintSession != nil)
    case "loadModel":
      let args = call.arguments as? [String: Any]
      let assetName = (args?["modelAsset"] as? String) ?? ""
      queue.async { [weak self] in
        guard let self = self else { return }
        do {
          try self.loadModel(assetName: assetName)
          NSLog("[DepthCover] loadModel OK")
          DispatchQueue.main.async { result(true) }
        } catch {
          NSLog("[DepthCover] loadModel FAILED: \(error)")
          DispatchQueue.main.async {
            result(FlutterError(code: "LOAD_FAILED", message: "\(error)", details: nil))
          }
        }
      }
    case "loadInpaintModel":
      queue.async { [weak self] in
        guard let self = self else { return }
        do {
          try self.loadInpaintModel()
          NSLog("[DepthCover] loadInpaintModel OK")
          DispatchQueue.main.async { result(true) }
        } catch {
          NSLog("[DepthCover] loadInpaintModel FAILED: \(error)")
          DispatchQueue.main.async {
            result(FlutterError(code: "LOAD_FAILED", message: "\(error)", details: nil))
          }
        }
      }
    case "generate":
      guard let args = call.arguments as? [String: Any],
            let sourcePath = args["sourcePath"] as? String,
            let outDir = args["outDir"] as? String,
            let key = args["key"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "generate requires sourcePath/outDir/key", details: nil))
        return
      }
      guard session != nil else {
        result(FlutterError(code: "MODEL_NOT_LOADED", message: "call loadModel first", details: nil))
        return
      }
      // 单飞行守卫：同 key 在途直接返回 null，失败路径移除以便重试
      guard markInFlight(key) else {
        result(nil)
        return
      }
      queue.async { [weak self] in
        guard let self = self else { return }
        defer { self.clearInFlight(key) }
        do {
          NSLog("[DepthCover] generate begin: key=\(key) src=\(sourcePath)")
          let paths = try self.runOnBigStack {
            try self.generate(sourcePath: sourcePath, sourceBytes: nil, outDir: outDir)
          }
          NSLog("[DepthCover] generate OK: \(paths.joined(separator: ","))")
          DispatchQueue.main.async { result(["layers": paths]) }
        } catch {
          NSLog("[DepthCover] generate FAILED: \(error)")
          DispatchQueue.main.async {
            result(FlutterError(code: "GENERATE_FAILED", message: "\(error)", details: nil))
          }
        }
      }
    case "generateDepth":
      guard let args = call.arguments as? [String: Any],
            let sourcePath = args["sourcePath"] as? String,
            let outDir = args["outDir"] as? String,
            let key = args["key"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "generateDepth requires sourcePath/outDir/key", details: nil))
        return
      }
      guard session != nil else {
        result(FlutterError(code: "MODEL_NOT_LOADED", message: "call loadModel first", details: nil))
        return
      }
      guard markInFlight(key) else {
        result(nil)
        return
      }
      queue.async { [weak self] in
        guard let self = self else { return }
        defer { self.clearInFlight(key) }
        do {
          NSLog("[DepthCover] generateDepth begin: key=\(key) src=\(sourcePath)")
          let out = try self.runOnBigStack {
            try self.generateDepth(sourcePath: sourcePath, sourceBytes: nil, outDir: outDir)
          }
          NSLog("[DepthCover] generateDepth OK: std=\(out.std) inpaint=\(out.inpaint)")
          DispatchQueue.main.async {
            result([
              "depth": out.depthPath,
              "depthStd": out.std,
              "bgFill": out.bgFillPath,
              "inpaint": out.inpaint,
            ])
          }
        } catch {
          NSLog("[DepthCover] generateDepth FAILED: \(error)")
          DispatchQueue.main.async {
            result(FlutterError(code: "GENERATE_FAILED", message: "\(error)", details: nil))
          }
        }
      }
    case "showToast":
      // iOS 无系统 toast，降级为日志（与 Android Toast 语义对齐的最佳近似）
      let msg = (call.arguments as? [String: Any])?["message"] as? String ?? ""
      NSLog("[DepthCover] toast: %@", msg)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func markInFlight(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if inFlight.contains(key) { return false }
    inFlight.insert(key)
    return true
  }

  private func clearInFlight(_ key: String) {
    lock.lock()
    defer { lock.unlock() }
    inFlight.remove(key)
  }

  // MARK: 大栈线程执行
  // iOS 主线程栈 1MB、GCD 池线程仅 512KB；ORT 图执行（尤其 migan pipeline 的
  // 512×512 图像算子链）会吃穿 512KB 栈 → SIGSEGV 且无任何 ORT 错误输出
  // （nr3 崩点实测）。Android 同代码线程栈 >=1MB 无此问题。深度模型（ViT
  // matmul 工作在堆上）侥幸不溢，但统一把推理全程调度到 64MB 栈 pthread。

  private final class BigStackWork {
    let work: () throws -> Any
    var result: Result<Any, Error>?
    let done = DispatchSemaphore(value: 0)
    init(_ work: @escaping () throws -> Any) { self.work = work }
  }

  private func bigStackEntry(_ arg: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let w = Unmanaged<BigStackWork>.fromOpaque(arg).takeRetainedValue()
    w.result = Result<Any, Error> { try w.work() }
    w.done.signal()
    return nil
  }

  private func runOnBigStack<T>(_ work: @escaping () throws -> T) throws -> T {
    let wrapped = BigStackWork { try work() }
    var attr = pthread_attr_t()
    pthread_attr_init(&attr)
    pthread_attr_setstacksize(&attr, 64 << 20)
    var tid: pthread_t?
    let op = Unmanaged.passRetained(wrapped).toOpaque()
    let rc = pthread_create(&tid, &attr, { arg in
      // @convention(c) 不能捕获上下文，经 arg 转回
      DepthCoverPlugin.shared.bigStackEntry(arg)
    }, op)
    pthread_attr_destroy(&attr)
    guard rc == 0 else {
      Unmanaged<BigStackWork>.fromOpaque(op).release()
      throw DepthError.failed("pthread_create failed: \(rc)")
    }
    wrapped.done.wait()
    switch wrapped.result! {
    case .success(let v): return v as! T
    case .failure(let e): throw e
    }
  }

  // MARK: 模型加载

  /// 模型文件定位：CI 在 3D 构建时把 android 侧模型拷入 Runner.app/models/。
  /// 依次尝试 models/ 目录 → bundle 根目录。
  private func bundleModelPath(_ name: String, _ ext: String) -> String? {
    if let p = Bundle.main.path(forResource: name, ofType: ext, inDirectory: "models") {
      return p
    }
    return Bundle.main.path(forResource: name, ofType: ext)
  }

  private func ensureOrt() throws {
    if api != nil { return }
    guard let base = OrtGetApiBase() else {
      throw DepthError.failed("OrtGetApiBase unavailable")
    }
    guard let raw = base.pointee.GetApi(Ort.apiVersion) else {
      throw DepthError.failed("OrtGetApiBase().GetApi(\(Ort.apiVersion)) returned null")
    }
    api = raw.assumingMemoryBound(to: OrtApi.self)
    if let ver = ortVersionString() {
      NSLog("[DepthCover] onnxruntime version %@", ver)
    }
  }

  private func ensureEnv() throws {
    guard let api = api else { throw DepthError.failed("ORT api not initialized") }
    if env == nil {
      var e: OpaquePointer?
      try ortCheck(api.pointee.CreateEnv(Ort.loggingWarning, "depth_cover", &e), "CreateEnv")
      env = e
    }
    if memInfo == nil {
      var m: OpaquePointer?
      try ortCheck(api.pointee.CreateCpuMemoryInfo(Ort.arenaAllocator, Ort.memTypeDefault, &m), "CreateCpuMemoryInfo")
      memInfo = m
    }
    if allocator == nil {
      var al: OpaquePointer?
      try ortCheck(api.pointee.GetAllocatorWithDefaultOptions(&al), "GetAllocatorWithDefaultOptions")
      allocator = al
    }
  }

  private func createSession(modelData: Data) throws -> OpaquePointer {
    guard let api = api, let env = env, let memInfo = memInfo else {
      throw DepthError.failed("ORT not initialized")
    }
    // 会话选项：4 线程 + 禁用图优化（对齐 Android NO_OPT，裁剪模型缺融合内核）
    var opts: OpaquePointer?
    try ortCheck(api.pointee.CreateSessionOptions(&opts), "CreateSessionOptions")
    defer { if let o = opts { api.pointee.ReleaseSessionOptions(o) } }
    try ortCheck(api.pointee.SetIntraOpNumThreads(opts, 4), "SetIntraOpNumThreads")
    try ortCheck(api.pointee.SetSessionGraphOptimizationLevel(opts, Ort.disableAll), "SetSessionGraphOptimizationLevel")
    var out: OpaquePointer?
    try modelData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      try ortCheck(
        api.pointee.CreateSessionFromArray(env, raw.baseAddress, raw.count, opts, &out),
        "CreateSessionFromArray")
    }
    guard let s = out else { throw DepthError.failed("CreateSessionFromArray returned null session") }
    return s
  }

  private func loadModel(assetName: String) throws {
    try ensureOrt()
    try ensureEnv()
    guard let api = api else { return }
    // Dart 只传 modelAsset（models/xxx.onnx）；按 basename 在 bundle 内定位
    let base = (assetName as NSString).lastPathComponent
    let name = (base as NSString).deletingPathExtension
    let ext = (base as NSString).pathExtension
    let resolvedName = name.isEmpty ? Self.depthModelName : name
    let resolvedExt = ext.isEmpty ? "onnx" : ext
    guard let path = bundleModelPath(resolvedName, resolvedExt) else {
      throw DepthError.failed("model not found in bundle: \(resolvedName).\(resolvedExt)")
    }
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw DepthError.failed("read model failed: \(error)")
    }
    NSLog("[DepthCover] loadModel begin: %@ (%d bytes)", path, data.count)
    let s = try createSession(modelData: data)
    // 新会话创建成功后再释放旧会话（失败时保留旧会话可用）。
    // 关键：modelData 必须保活到会话释放 —— CreateSessionFromArray 零拷贝引用
    // buffer（大 initializer 直接指向原内存），Run 时才真正读权重；
    // 若 data 随局部作用域释放 → 首次 Run 访问悬垂指针 → SIGBUS。
    if let old = session { api.pointee.ReleaseSession(old) }
    session = s
    depthModelData = data
  }

  private func loadInpaintModel() throws {
    try ensureOrt()
    try ensureEnv()
    guard let api = api else { return }
    guard let path = bundleModelPath(Self.inpaintModelName, "onnx") else {
      throw DepthError.failed("inpaint model not found in bundle: \(Self.inpaintModelName).onnx")
    }
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw DepthError.failed("read inpaint model failed: \(error)")
    }
    NSLog("[DepthCover] loadInpaintModel begin: %@ (%d bytes)", path, data.count)
    let s = try createSession(modelData: data)
    // modelData 保活到会话释放（同 loadModel，CreateSessionFromArray 零拷贝引用）
    if let old = inpaintSession { api.pointee.ReleaseSession(old) }
    inpaintSession = s
    inpaintModelData = data
  }

  // MARK: generate（三层切割）

  private struct Cover {
    var rgba: [UInt8]
    var w: Int
    var h: Int
  }

  private func generate(sourcePath: String, sourceBytes: Data?, outDir: String) throws -> [String] {
    guard let session = session else { throw DepthError.failed("session null") }
    let src = try decodeCover(path: sourcePath, bytes: sourceBytes)
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    // 1) 推理 + min-max 归一化到 0..1（值越大越近）
    let norm = normalize(try infer(session, src))

    // 2) 背景修补：layer0 从修补像素切割（主体被抠走处已填充，不再有透明洞）
    let filled = inpaintBackground(src, norm)

    // 3) 深度带切割：layer0=远(背景) layer2=近(前景)，平滑羽化避免硬边
    var paths: [String] = []
    let filledCover = Cover(rgba: filled, w: src.w, h: src.h)
    for (li, band) in Self.bands.enumerated() {
      let layer = splitLayer(li == 0 ? filledCover : src, norm, lo: band.0, hi: band.1)
      let f = URL(fileURLWithPath: outDir).appendingPathComponent("layer\(li).png").path
      try writePNGRGBA(layer, w: src.w, h: src.h, to: f)
      paths.append(f)
    }
    return paths
  }

  // MARK: generateDepth（深度图 + 背景修补）

  private struct DepthResult {
    var depthPath: String
    var std: Double
    var bgFillPath: String
    var inpaint: String
  }

  private func generateDepth(sourcePath: String, sourceBytes: Data?, outDir: String) throws -> DepthResult {
    guard let session = session else { throw DepthError.failed("session null") }
    NSLog("[DepthCover] gd1: decode begin")
    let src = try decodeCover(path: sourcePath, bytes: sourceBytes)
    NSLog("[DepthCover] gd2: decode done %dx%d", src.w, src.h)
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    let norm = normalize(try infer(session, src))
    NSLog("[DepthCover] gd11: infer+normalize done")
    let std = depthStd(norm)

    // --- 背景修补（push-pull + 深度保边平滑）：洞区被填充，
    // 供 shader 遮挡失配回退采样（消除轮廓拉伸伪影） ---
    let patched = inpaintBackgroundWithMask(src, norm)
    var filled = patched.filled
    let mask = patched.mask

    // --- 神经细化（可选）：MI-GAN pipeline 会话就绪时对洞区二次填充，
    // 失败保底 push-pull 结果。开关由 Dart 侧控制（未开启不加载会话，直接跳过） ---
    NSLog("[DepthCover] gd12: pushpull done")
    var usedNeural = false
    if let s2 = inpaintSession {
      usedNeural = neuralRefine(src, mask, &filled, w: src.w, h: src.h, session: s2)
      if usedNeural { NSLog("[DepthCover] neuralRefine OK (migan)") }
    }
    NSLog("[DepthCover] gd13: neural done used=%d", usedNeural ? 1 : 0)

    let w = src.w, h = src.h
    let outDirURL = URL(fileURLWithPath: outDir)

    let bgFillPath = outDirURL.appendingPathComponent("bg_fill.png").path
    try writePNGRGBA(filled, w: w, h: h, to: bgFillPath)
    NSLog("[DepthCover] gd14: bg_fill png OK: %@ inpaint=%@", bgFillPath, usedNeural ? "migan" : "pushpull")

    // 灰度 8-bit（R=G=B=gray, A=255）@378×378
    let d = Self.depthSize
    var gray = [UInt8](repeating: 0, count: d * d * 4)
    for i in 0..<(d * d) {
      let g = UInt8(min(max(Int(norm[i] * 255), 0), 255))
      gray[i * 4] = g
      gray[i * 4 + 1] = g
      gray[i * 4 + 2] = g
      gray[i * 4 + 3] = 255
    }
    let depthPath = outDirURL.appendingPathComponent("depth.png").path
    try writePNGRGBA(gray, w: d, h: d, to: depthPath)
    NSLog("[DepthCover] gd15: depth png OK std=\(std)")

    return DepthResult(
      depthPath: depthPath, std: Double(std),
      bgFillPath: bgFillPath, inpaint: usedNeural ? "migan" : "pushpull")
  }

  // MARK: 推理

  /// Depth Anything V2 推理：378×378 NCHW float 输入，输出摊平 FloatArray
  /// （兼容 (1,1,H,W) 与 (1,H,W)）。
  private func infer(_ session: OpaquePointer, _ src: Cover) throws -> [Float] {
    guard let api = api, let memInfo = memInfo else { throw DepthError.failed("ORT not initialized") }
    let d = Self.depthSize
    let scaled = scaledRGBA(src, d, d)
    NSLog("[DepthCover] gd3: scaled done %dx%d", scaled.w, scaled.h)

    // NCHW float + ImageNet 归一化
    var data = [Float](repeating: 0, count: 3 * d * d)
    for c in 0..<3 {
      let plane = c * d * d
      let mean = Self.mean[c], std = Self.std[c]
      for i in 0..<(d * d) {
        data[plane + i] = (Float(scaled.rgba[i * 4 + c]) / 255.0 - mean) / std
      }
    }
    NSLog("[DepthCover] gd5: normalize done")

    let inName = try sessionInputName(session, 0)
    let outName = try sessionOutputName(session, 0)
    NSLog("[DepthCover] gd6: names done in=%@ out=%@", inName, outName)

    var shape: [Int64] = [1, 3, Int64(d), Int64(d)]
    var tensor: OpaquePointer?
    var creationStatus: OpaquePointer?
    // data 缓冲不拷贝、被 tensor 引用，必须在 Run 结束前保活（同一作用域内）
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      creationStatus = api.pointee.CreateTensorWithDataAsOrtValue(
        memInfo, raw.baseAddress, raw.count, shape, shape.count, Ort.typeFloat, &tensor)
    }
    try ortCheck(creationStatus, "create input tensor")
    defer { if let t = tensor { api.pointee.ReleaseValue(t) } }
    guard tensor != nil else { throw DepthError.failed("input tensor null") }
    NSLog("[DepthCover] gd7: tensor done")

    var outValue: OpaquePointer?
    try withCStrings([inName, outName]) { names in
      var inputs: [OpaquePointer?] = [tensor]
      var outputs: [OpaquePointer?] = [nil]
      var inNames: [UnsafePointer<CChar>?] = [names[0]]
      var outNames: [UnsafePointer<CChar>?] = [names[1]]
      NSLog("[DepthCover] gd8: Run begin")
      try ortCheck(api.pointee.Run(session, nil, inNames, inputs, 1, outNames, 1, &outputs), "Run")
      NSLog("[DepthCover] gd9: Run done")
      outValue = outputs[0]
    }
    guard let ov = outValue else { throw DepthError.failed("Run produced no output") }
    defer { api.pointee.ReleaseValue(ov) }

    let (_, count) = try tensorDims(ov)
    var ptr: UnsafeMutableRawPointer?
    try ortCheck(api.pointee.GetTensorMutableData(ov, &ptr), "GetTensorMutableData")
    guard let p = ptr else { throw DepthError.failed("output data null") }
    let floats = p.assumingMemoryBound(to: Float.self)
    let result = Array(UnsafeBufferPointer(start: floats, count: count))
    NSLog("[DepthCover] gd10: out data done count=%d", count)
    return result
  }

  // MARK: 背景修补管线（generate/generateDepth 共用）

  private struct InpaintOutput {
    var filled: [UInt8]
    var mask: [Float]
  }

  /// 返回 (修补后整幅背景 RGBA8, 膨胀后的前景掩码 @378 网格)。
  private func inpaintBackgroundWithMask(_ src: Cover, _ norm: [Float]) -> InpaintOutput {
    let d = Self.depthSize
    // 引导图：原图灰度下采样到深度网格（亮度差约束滤波权重，主体边缘不跨边模糊）
    let small = scaledRGBA(src, d, d)
    var guide = [Float](repeating: 0, count: d * d)
    for i in 0..<(d * d) {
      let p = i * 4
      guide[i] = (0.299 * Float(small.rgba[p]) + 0.587 * Float(small.rgba[p + 1])
        + 0.114 * Float(small.rgba[p + 2])) / 255
    }
    let smoothDepth = InpaintTools.jointBilateralSmooth(norm, guide, d)
    // 掩码膨胀：洞向外扩 MASK_DILATE_RADIUS 像素（@378 网格），把主体过渡带
    // （发丝/抗锯齿混合色）吞进洞里，填充源只来自纯净背景——消除轮廓污染环
    let mask = InpaintTools.dilateHole(
      InpaintTools.fgMask(smoothDepth, d: d), d: d, radius: Self.maskDilateRadius)
    // 双线性放大到原图分辨率（替代最近邻，消除掩码锯齿边）
    var maskFull = [Float](repeating: 0, count: src.w * src.h)
    for y in 0..<src.h {
      let fy = (Float(y) + 0.5) * Float(d) / Float(src.h) - 0.5
      for x in 0..<src.w {
        let fx = (Float(x) + 0.5) * Float(d) / Float(src.w) - 0.5
        maskFull[y * src.w + x] = sampleMaskBilinear(mask, d: d, fx: fx, fy: fy)
      }
    }
    let filled = PullPushFiller.fill(src.rgba, src.w, src.h, maskFull)
    return InpaintOutput(filled: filled, mask: mask)
  }

  private func inpaintBackground(_ src: Cover, _ norm: [Float]) -> [UInt8] {
    inpaintBackgroundWithMask(src, norm).filled
  }

  /// 神经细化（MI-GAN）：官方 pipeline 自带 crop/缩放/blending，Kotlin 只喂
  /// uint8 NCHW 原图 + uint8 掩码，输出与输入同分辨率且非洞区像素与原图一致，
  /// 直接整体覆盖 filled。返回 true=已覆盖；任何异常=false（保底 push-pull）。
  /// 注意：pipeline 掩码协议 255=known、0=hole，与 fgMask 相反，此处已反转。
  private func neuralRefine(
    _ src: Cover, _ mask: [Float], _ filled: inout [UInt8],
    w: Int, h: Int, session: OpaquePointer
  ) -> Bool {
    do {
      guard let api = api, let memInfo = memInfo else { return false }
      let d = Self.depthSize
      NSLog("[DepthCover] nr1: begin %dx%d", w, h)
      // 1) 膨胀掩码 → 反转 → uint8（双线性上采样与 push-pull 同一几何）。
      //    官方要求掩码必须二值：连续值会让 pipeline 的 crop/blending 在
      //    过渡带产生彩色镶边，故此处硬阈值化。
      var maskU8 = [UInt8](repeating: 0, count: w * h)
      for y in 0..<h {
        let fy = (Float(y) + 0.5) * Float(d) / Float(h) - 0.5
        for x in 0..<w {
          let fx = (Float(x) + 0.5) * Float(d) / Float(w) - 0.5
          let hole = sampleMaskBilinear(mask, d: d, fx: fx, fy: fy)
          maskU8[y * w + x] = hole >= 0.5 ? 0 : 255
        }
      }
      // 2) 原图 uint8 RGB —— 必须按 NCHW 平面布局（R 平面→G 平面→B 平面），
      //    与签名 [1,3,H,W] 一致（交错 packed RGB 会导致洞区色块噪声）。
      var rgb = [UInt8](repeating: 0, count: w * h * 3)
      let plane = w * h
      for i in 0..<(w * h) {
        let p = i * 4
        rgb[i] = src.rgba[p]
        rgb[plane + i] = src.rgba[p + 1]
        rgb[2 * plane + i] = src.rgba[p + 2]
      }
      // 3) 按张量维度识别 image/mask 输入名（image: dim1==3；mask: dim1==1）
      let inCount: Int
      var cnt: Int = 0
      try ortCheck(api.pointee.SessionGetInputCount(session, &cnt), "SessionGetInputCount")
      inCount = cnt
      var imgName: String?
      var mskName: String?
      for idx in 0..<inCount {
        guard let dims = try sessionInputDims(session, idx) else { continue }
        if dims.count >= 2 && dims[1] == 3 {
          imgName = try sessionInputName(session, idx)
        } else {
          mskName = try sessionInputName(session, idx)
        }
      }
      guard let img = imgName, let msk = mskName else {
        throw DepthError.failed("unexpected inpaint model inputs")
      }
      NSLog("[DepthCover] nr2: dims+names done img=%@ msk=%@", img, msk)
      // 4) 推理（uint8 NCHW）
      var shapeImg: [Int64] = [1, 3, Int64(h), Int64(w)]
      var shapeMask: [Int64] = [1, 1, Int64(h), Int64(w)]
      var tImg: OpaquePointer?
      var tMask: OpaquePointer?
      var sImg: OpaquePointer?
      var sMask: OpaquePointer?
      rgb.withUnsafeMutableBytes { (rr: UnsafeMutableRawBufferPointer) in
        sImg = api.pointee.CreateTensorWithDataAsOrtValue(
          memInfo, rr.baseAddress, rr.count, shapeImg, shapeImg.count, Ort.typeUint8, &tImg)
      }
      try ortCheck(sImg, "create migan image tensor")
      guard tImg != nil else { throw DepthError.failed("migan image tensor null") }
      defer { if let t = tImg { api.pointee.ReleaseValue(t) } }
      maskU8.withUnsafeMutableBytes { (rm: UnsafeMutableRawBufferPointer) in
        sMask = api.pointee.CreateTensorWithDataAsOrtValue(
          memInfo, rm.baseAddress, rm.count, shapeMask, shapeMask.count, Ort.typeUint8, &tMask)
      }
      try ortCheck(sMask, "create migan mask tensor")
      guard tMask != nil else { throw DepthError.failed("migan mask tensor null") }
      defer { if let t = tMask { api.pointee.ReleaseValue(t) } }

      let outName = try sessionOutputName(session, 0)
      var outValue: OpaquePointer?
      NSLog("[DepthCover] nr3: tensors done, Run begin")
      try withCStrings([img, msk, outName]) { names in
        var inputs: [OpaquePointer?] = [tImg, tMask]
        var outputs: [OpaquePointer?] = [nil]
        var inNames: [UnsafePointer<CChar>?] = [names[0], names[1]]
        var outNames: [UnsafePointer<CChar>?] = [names[2]]
        try ortCheck(api.pointee.Run(session, nil, inNames, inputs, 2, outNames, 1, &outputs), "migan Run")
        outValue = outputs[0]
      }
      NSLog("[DepthCover] nr4: Run done")
      guard let ov = outValue else { throw DepthError.failed("migan Run no output") }
      defer { api.pointee.ReleaseValue(ov) }
      let (_, count) = try tensorDims(ov)
      guard count >= 3 * plane else { throw DepthError.failed("migan output too small: \(count)") }
      var ptr: UnsafeMutableRawPointer?
      try ortCheck(api.pointee.GetTensorMutableData(ov, &ptr), "migan GetTensorMutableData")
      guard let p = ptr else { throw DepthError.failed("migan output data null") }
      let outBytes = p.assumingMemoryBound(to: UInt8.self)
      // 输出 [1,3,H,W] uint8（NCHW）；非洞区与原图一致，直接覆盖
      for i in 0..<plane {
        filled[i * 4] = outBytes[i]
        filled[i * 4 + 1] = outBytes[plane + i]
        filled[i * 4 + 2] = outBytes[2 * plane + i]
        filled[i * 4 + 3] = 255
      }
      return true
    } catch {
      NSLog("[DepthCover] neuralRefine failed, keep push-pull result: \(error)")
      return false
    }
  }

  // MARK: 纯数学辅助

  /// 378 网格掩码的双线性采样（半像素中心对齐）。
  private func sampleMaskBilinear(_ mask: [Float], d: Int, fx: Float, fy: Float) -> Float {
    let x0 = min(max(Int(fx), 0), d - 1)
    let y0 = min(max(Int(fy), 0), d - 1)
    let x1 = min(x0 + 1, d - 1)
    let y1 = min(y0 + 1, d - 1)
    let tx = min(max(fx - Float(x0), 0), 1)
    let ty = min(max(fy - Float(y0), 0), 1)
    let a = mask[y0 * d + x0] * (1 - tx) + mask[y0 * d + x1] * tx
    let b = mask[y1 * d + x0] * (1 - tx) + mask[y1 * d + x1] * tx
    return a * (1 - ty) + b * ty
  }

  /// min-max 归一化到 0..1（值越大越近）。
  private func normalize(_ depth: [Float]) -> [Float] {
    var mn = Float.greatestFiniteMagnitude
    var mx = -Float.greatestFiniteMagnitude
    for v in depth {
      if v < mn { mn = v }
      if v > mx { mx = v }
    }
    let range = max(mx - mn, 1e-6)
    return depth.map { ($0 - mn) / range }
  }

  /// 深度图标准差（stride 采样，ShengChao computeDepthStd 同款）。
  private func depthStd(_ norm: [Float]) -> Float {
    var sum: Float = 0, sumSq: Float = 0, n: Float = 0
    var i = 0
    while i < norm.count {
      let v = norm[i]
      sum += v
      sumSq += v * v
      n += 1
      i += 4
    }
    if n == 0 { return 0.18 }
    let mean = sum / n
    let variance = max(sumSq / n - mean * mean, 0)
    return sqrt(variance)
  }

  /// 深度在 [lo,hi] 带内的像素保留，带外按 feather 线性羽化为透明。
  /// 输出保持封面原分辨率；norm 为推理分辨率网格，按 (x,y) 最近邻映射取深度。
  private func splitLayer(_ src: Cover, _ norm: [Float], lo: Float, hi: Float) -> [UInt8] {
    let d = Self.depthSize
    let feather = Self.feather
    var pixels = src.rgba
    let w = src.w, h = src.h
    for y in 0..<h {
      let dy = min(y * d / h, d - 1)
      for x in 0..<w {
        let dx = min(x * d / w, d - 1)
        let dep = norm[dy * d + dx]
        let a: Float
        if dep < lo - feather || dep > hi + feather {
          a = 0
        } else if dep < lo {
          a = (dep - (lo - feather)) / feather
        } else if dep > hi {
          a = ((hi + feather) - dep) / feather
        } else {
          a = 1
        }
        let i = (y * w + x) * 4
        if a <= 0 {
          pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
        } else if a < 1 {
          pixels[i + 3] = UInt8(a * 255)
        }
      }
    }
    return pixels
  }

  // MARK: 图像 IO

  /// 解码封面为 RGBA8（路径解码失败时回退字节数据，对齐 Android decodeFile/decodeByteArray）。
  private func decodeCover(path: String?, bytes: Data?) throws -> Cover {
    var source: CGImageSource?
    if let path = path, FileManager.default.fileExists(atPath: path) {
      source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    }
    if source == nil, let bytes = bytes {
      source = CGImageSourceCreateWithData(bytes as CFData, nil)
    }
    guard let s = source,
          let img = CGImageSourceCreateImageAtIndex(s, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else {
      throw DepthError.failed("cannot decode cover")
    }
    return renderToRGBA(img, w: img.width, h: img.height)
  }

  /// 绘制到 w×h RGBA8 位图（premultipliedLast；封面不透明场景下等价直通）。
  private func renderToRGBA(_ img: CGImage, w: Int, h: Int) -> Cover {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      guard let base = raw.baseAddress,
            let ctx = CGContext(
              data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      ctx.interpolationQuality = .high
      ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Cover(rgba: buf, w: w, h: h)
  }

  private func scaledRGBA(_ src: Cover, _ w: Int, _ h: Int) -> Cover {
    if src.w == w && src.h == h { return src }
    guard let img = cgImage(from: src.rgba, w: src.w, h: src.h, alpha: .premultipliedLast) else {
      return src
    }
    return renderToRGBA(img, w: w, h: h)
  }

  /// RGBA8 → CGImage。alpha 指定输出解释方式：
  /// - .last：非预乘（splitLayer 的半透明边缘直通，PNG 编码保持直通 alpha）
  /// - .premultipliedLast：位图渲染源（renderToRGBA 的上下文即此格式）
  private func cgImage(from rgba: [UInt8], w: Int, h: Int, alpha: CGImageAlphaInfo) -> CGImage? {
    // CGDataProvider(data:) 是 Get 语义、不持有 CFData —— 局部 Data 释放后
    // provider 悬垂，绘制/PNG 编码时 SIGSEGV。用 dataInfo + releaseData 回调
    // 把 Data 生命周期绑定到 provider（CGImage 持有 provider，最后自动释放）。
    let nsData = Data(rgba) as NSData
    guard let provider = CGDataProvider(
      dataInfo: Unmanaged.passRetained(nsData).toOpaque(),
      data: nsData.bytes,
      size: nsData.length,
      releaseData: { info, _, _ in
        if let info = info { Unmanaged<NSData>.fromOpaque(info).release() }
      })
    else {
      Unmanaged.passRetained(nsData).release() // 创建失败时手动归还所有权
      return nil
    }
    return CGImage(
      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// RGBA8 → PNG（CGImageAlphaInfo.last：非预乘，PNG 原生语义，半透明边缘不失真）。
  private func writePNGRGBA(_ rgba: [UInt8], w: Int, h: Int, to path: String) throws {
    guard let img = cgImage(from: rgba, w: w, h: h, alpha: .last) else {
      throw DepthError.failed("create CGImage failed: \(path)")
    }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
      throw DepthError.failed("create PNG destination failed: \(path)")
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw DepthError.failed("write PNG failed: \(path)")
    }
  }

  // MARK: ORT 会话元信息

  private func ortCheck(_ status: OpaquePointer?, _ ctx: String) throws {
    guard let s = status else { return } // nullptr = 成功
    let msg: String
    if let api = api, let c = api.pointee.GetErrorMessage(s) {
      msg = String(cString: c)
    } else {
      msg = "unknown ORT error"
    }
    api?.pointee.ReleaseStatus(s)
    throw DepthError.ort("\(ctx): \(msg)")
  }

  private func sessionInputName(_ session: OpaquePointer, _ index: Int) throws -> String {
    guard let api = api, let al = allocator else { throw DepthError.failed("ORT api/allocator null") }
    var name: UnsafeMutablePointer<CChar>?
    try ortCheck(api.pointee.SessionGetInputName(session, index, al, &name), "SessionGetInputName")
    guard let n = name else { throw DepthError.failed("SessionGetInputName returned null") }
    let s = String(cString: n)
    api.pointee.AllocatorFree(al, UnsafeMutableRawPointer(n))
    return s
  }

  private func sessionOutputName(_ session: OpaquePointer, _ index: Int) throws -> String {
    guard let api = api, let al = allocator else { throw DepthError.failed("ORT api/allocator null") }
    var name: UnsafeMutablePointer<CChar>?
    try ortCheck(api.pointee.SessionGetOutputName(session, index, al, &name), "SessionGetOutputName")
    guard let n = name else { throw DepthError.failed("SessionGetOutputName returned null") }
    let s = String(cString: n)
    api.pointee.AllocatorFree(al, UnsafeMutableRawPointer(n))
    return s
  }

  /// 张量维度与元素数（兼容 (1,1,H,W)/(1,H,W)）。
  private func tensorDims(_ value: OpaquePointer) throws -> (dims: [Int64], count: Int) {
    guard let api = api else { throw DepthError.failed("ORT api null") }
    var info: OpaquePointer?
    try ortCheck(api.pointee.GetTensorTypeAndShape(value, &info), "GetTensorTypeAndShape")
    guard let i = info else { throw DepthError.failed("GetTensorTypeAndShape returned null") }
    defer { api.pointee.ReleaseTensorTypeAndShapeInfo(i) }
    var rank: Int = 0
    try ortCheck(api.pointee.GetDimensionsCount(i, &rank), "GetDimensionsCount")
    guard rank > 0 else { throw DepthError.failed("rank=0") }
    var dims = [Int64](repeating: 0, count: rank)
    try ortCheck(api.pointee.GetDimensions(i, &dims, rank), "GetDimensions")
    var count = 1
    for dv in dims { count *= Int(dv) }
    return (dims, count)
  }

  /// 输入张量维度（MI-GAN image/mask 识别用）；非张量输入返回 nil。
  /// 注意：CastTypeInfoToTensorInfo 返回借用指针（头文件明言 "Do not free this
  /// value, it will be valid until type_info is freed"），绝不能对返回值调
  /// ReleaseTensorTypeAndShapeInfo —— 释放 OrtTypeInfo 仍持有的内存会导致堆损坏
  /// SIGSEGV（此前七轮闪退的最后根因）；只需释放外层 OrtTypeInfo 本身。
  private func sessionInputDims(_ session: OpaquePointer, _ index: Int) throws -> [Int64]? {
    guard let api = api else { throw DepthError.failed("ORT api null") }
    var ti: OpaquePointer?
    try ortCheck(api.pointee.SessionGetInputTypeInfo(session, index, &ti), "SessionGetInputTypeInfo")
    guard let t = ti else { return nil }
    defer { api.pointee.ReleaseTypeInfo(t) }
    var tsi: OpaquePointer?
    try ortCheck(api.pointee.CastTypeInfoToTensorInfo(t, &tsi), "CastTypeInfoToTensorInfo")
    guard let ts = tsi else { return nil }
    var rank: Int = 0
    try ortCheck(api.pointee.GetDimensionsCount(ts, &rank), "GetDimensionsCount")
    guard rank > 0 else { return [] }
    var dims = [Int64](repeating: 0, count: rank)
    try ortCheck(api.pointee.GetDimensions(ts, &dims, rank), "GetDimensions")
    return dims
  }

  // MARK: C 字符串辅助

  /// 把字符串数组以 withCString 嵌套方式转成 C 指针数组（生命周期覆盖 body）。
  private func withCStrings(
    _ strings: [String], index: Int = 0, acc: [UnsafePointer<CChar>?] = [],
    _ body: ([UnsafePointer<CChar>?]) throws -> Void
  ) rethrows {
    if index == strings.count {
      try body(acc)
    } else {
      try strings[index].withCString { cs in
        var next = acc
        next.append(cs)
        try withCStrings(strings, index: index + 1, acc: next, body)
      }
    }
  }
}

#endif // DEPTH_3D_LINKED
