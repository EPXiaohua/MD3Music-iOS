/// 一次 Release 查询的结果（纯数据，不依赖任何网络/Flutter 类型）。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.version,
    required this.htmlUrl,
  });

  /// 由 GitHub tag 构造：剥离 `v` 前缀与 `+<build>` 构建号写入 [version] 供展示。
  ///
  /// 本仓库 tag 形如 `v5.8.1+47`（CI 用 --build-name/--build-number 打），
  /// 而本地 pubspec `version` 不含构建号（PackageInfo.version = `5.8.1`）。
  /// 展示与「已提醒去重」都应基于三段版本号，否则 toast / 设置页会露出
  /// `+47`，且与本地版本字面不等。`tagName` 保留原样（跳转链接仍指向完整 tag）。
  factory ReleaseInfo.fromTag({
    required String tagName,
    required String htmlUrl,
  }) {
    final tag = tagName.trim();
    var bare = (tag.startsWith('v') || tag.startsWith('V'))
        ? tag.substring(1)
        : tag;
    // 截断构建号（+47）与预发布后缀（-beta）：与 parseReleaseVersion 同口径
    bare = bare.split('+').first.split('-').first;
    return ReleaseInfo(tagName: tag, version: bare, htmlUrl: htmlUrl);
  }

  /// 原始 tag，形如 `v5.6.5`。
  final String tagName;

  /// 去掉 `v` 前缀的版本号，形如 `5.6.5`。
  final String version;

  /// Release 页面地址（供跳转下载）。
  final String htmlUrl;
}

/// Release 数据来源抽象：让 [UpdateCheckService] 可在测试中注入假实现，不联网。
abstract class ReleaseSource {
  /// 查询最新 Release。查不到（网络失败 / 无 Release / 响应异常）返回 null。
  Future<ReleaseInfo?> fetchLatest();
}
