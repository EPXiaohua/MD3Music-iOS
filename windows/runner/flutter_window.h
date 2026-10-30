#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <mutex>
#include <vector>

#include "win32_window.h"
#include "floating_lyric_window.h"
#include "media_controls.h"
#include "spectrum_capture.h"
#include "taskbar_controls.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 启动、任务栏重建和隐藏窗口前均确认托盘图标仍然存在。
  bool EnsureTrayIcon();

  // 频谱帧：采集线程写入最新一帧并 PostMessage 唤醒本窗口，这里在平台线程
  // 上补发 onFft（跨线程直接发平台通道消息会要求 messenger 锁）。
  void HandleSpectrumFrame();

  // 无边框窗口全屏（覆盖整个显示器，含任务栏）。
  //
  // 不用 SW_MAXIMIZE：最大化只铺到工作区（rcWork），任务栏仍可见，
  // 达不到「Zen 完全全屏」的语义。这里临时去掉标题/边框样式，再把窗口
  // 摆到显示器 rcMonitor 上，退出时按进入前的快照（样式 + 窗口位置）恢复。
  // 幂等：已是目标状态时直接返回。
  void SetFullscreen(bool fullscreen);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> lyric_channel_;
  // fluttertoast 在 Windows 无实现，这里使用非模态原生短暂提示。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> message_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;
  // 音乐频谱：与 Android 同一通道名/同一 onFft 协议，Dart 侧无需分叉。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      spectrum_channel_;
  // WASAPI 环回采集（进程环回优先，设备环回兜底）。
  SpectrumCapture spectrum_capture_;
  // 采集线程 → 平台线程的频谱帧信箱（只保留最新一帧，UI 不需要追帧）。
  static constexpr UINT kSpectrumFrameMessage = WM_APP + 2;
  std::mutex spectrum_frame_mutex_;
  std::vector<double> spectrum_pending_bands_;
  bool spectrum_frame_pending_ = false;
  FloatingLyricWindow floating_lyric_;
  // Windows 系统媒体传输控件（媒体浮层/锁屏/媒体键）。
  MediaControlsController media_controls_;
  // 任务栏按钮进度条 + 悬停缩略图工具栏（上一首/播放暂停/下一首）。
  TaskbarControls taskbar_controls_;
  bool tray_icon_added_ = false;
  bool exit_requested_ = false;
  // 当前是否处于无边框全屏。
  bool fullscreen_ = false;
  // 进入全屏前的窗口样式（GWL_STYLE）与形态/位置快照，退出全屏时原样恢复。
  LONG_PTR fullscreen_restore_style_ = 0;
  WINDOWPLACEMENT fullscreen_restore_placement_ = {sizeof(WINDOWPLACEMENT)};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
