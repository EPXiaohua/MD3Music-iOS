import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/app_toast.dart';

// 上游项目主页（Android/Windows 共用）。iOS 移植版走各自入口
// （settings_page 的 EPXiaohua/MD3Music-iOS releases / 项目仓库链接），
// 不引用本常量，故此处保持 const 字面量而非引用 GithubReleaseClient.owner。
const updateProjectUrl = 'https://github.com/zzyoxml/md3Music';
const updateMirrorWebsiteUrl =
    'https://git.hiwiki.org/zh-CN/repo/zzyoxml/md3music';

/// 网页下载是应用内更新之外的备用入口，交给系统默认浏览器处理。
Future<void> openUpdateWebPage(String url) async {
  try {
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      return;
    }
  } catch (_) {
    // 不影响更新弹窗或已有下载任务，失败反馈统一走原生 Toast。
  }
  showToast('无法打开浏览器，请手动访问：$url', long: true);
}
