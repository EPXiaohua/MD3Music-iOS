import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../main.dart' show appNavigatorKey;
import '../../modules/login/login_page.dart';
import '../../modules/personal_fm/personal_fm_core.dart';
import '../../modules/player/full_player_route.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import 'home_widget_service.dart';
import 'media_notification_service.dart';

/// 私人FM桌面小部件的状态推送协调器。
///
/// 监听 KugouProvider / PlayerProvider / FavoritesProvider，任一变化后
/// （150ms debounce + 快照内容去重）把 FM 卡片快照推给原生 RemoteViews；
/// 同时把原生按钮动作（经 MediaNotificationService 静态回调进来）接到
/// [PersonalFmWidgetActions]，并在档位切换前后推送加载态。
class FmWidgetSync {
  FmWidgetSync._();

  static final FmWidgetSync instance = FmWidgetSync._();

  KugouProvider? _kugou;
  PlayerProvider? _player;
  FavoritesProvider? _favorites;
  Timer? _debounce;
  bool _attached = false;
  bool _fmLoading = false;
  String? _lastPayload;
  /// 上一拍观察到的「当前歌曲收藏态」，用于判断收藏变化是否值得重推通知。
  bool _lastCurrentSongFavorited = false;
  /// 上述基线所属的歌曲 id：切歌后基线失效，需按新歌重新记录。
  String? _favoriteBaselineSongId;

  /// App 首帧后调用（provider 惰性 create 已就绪）。
  void attach({
    required KugouProvider kugou,
    required PlayerProvider player,
    required FavoritesProvider favorites,
  }) {
    if (_attached) return;
    _attached = true;
    _kugou = kugou;
    _player = player;
    _favorites = favorites;
    kugou.addListener(_scheduleSync);
    player.addListener(_scheduleSync);
    favorites.addListener(_onFavoritesChanged);
    _bindActions();
    _scheduleSync();
  }

  /// 收藏态变化：除了推 FM 快照，还要刷新通知/小组件载荷。
  /// 概念版 4×1 小组件的爱心取自 `isFavorited`，只在 _updateNotification 里
  /// 组装；不主动刷新的话，在 App 内点收藏后卡片爱心要等下一次切歌才更新。
  ///
  /// 只在「当前歌曲收藏态真的翻转」时刷新：FavoritesProvider 启动加载与
  /// 云端同步会连续 notifyListeners，无条件刷新会造成一批无谓的通知重建
  /// 与小组件广播（既有性能优化专门压过这类高频刷新）。切歌后基线随之失效，
  /// 按新歌重新记录——否则「上一首已收藏、切到未收藏的歌再点收藏」会被
  /// 误判成无变化。
  void _onFavoritesChanged() {
    _scheduleSync();
    final song = _player?.currentSong;
    if (song == null) return;
    final favorited = _favorites?.isFavorite(song.id) ?? false;
    final songChanged = song.id != _favoriteBaselineSongId;
    if (!songChanged && favorited == _lastCurrentSongFavorited) return;
    _favoriteBaselineSongId = song.id;
    _lastCurrentSongFavorited = favorited;
    _player?.refreshNotification();
  }

  /// 档位切换等动作的前后钩子：立即推送加载态，不等 debounce。
  void markFmLoading(bool loading) {
    if (_fmLoading == loading) return;
    _fmLoading = loading;
    // ignore: discarded_futures
    _push();
  }

  void _bindActions() {
    MediaNotificationService.onWidgetFmPlayPause = () {
      final kugou = _kugou;
      final player = _player;
      if (kugou == null || player == null || _fmLoading) return;
      // ignore: discarded_futures
      PersonalFmWidgetActions.handlePlayPause(kugou: kugou, player: player);
    };
    MediaNotificationService.onWidgetFmToggleFavorite = () {
      final kugou = _kugou;
      final player = _player;
      final favorites = _favorites;
      if (kugou == null || player == null || favorites == null) return;
      // ignore: discarded_futures
      PersonalFmWidgetActions.handleToggleFavorite(
        kugou: kugou,
        player: player,
        favorites: favorites,
      );
    };
    MediaNotificationService.onWidgetFmOpenTrack = (hash) {
      final kugou = _kugou;
      final player = _player;
      if (kugou == null || player == null) return;
      // ignore: discarded_futures
      PersonalFmWidgetActions.handleOpenTrack(
        kugou: kugou,
        player: player,
        hash: hash,
      );
    };
    MediaNotificationService.onWidgetFmSelectStation = (index) async {
      final kugou = _kugou;
      if (kugou == null || _fmLoading) return;
      markFmLoading(true);
      try {
        await PersonalFmWidgetActions.handleSelectStation(
          kugou: kugou,
          index: index,
        );
      } finally {
        markFmLoading(false);
      }
    };
    // 封面点击：app 已被拉起，打开播放器页（与发现页 _openPlayerDetail
    // 同一条 fullPlayerRoute 路由，已有播放页在栈顶时不重复压栈）
    MediaNotificationService.onWidgetFmOpenPlayer = () {
      final nav = appNavigatorKey.currentState;
      final navContext = appNavigatorKey.currentContext;
      if (nav == null || navContext == null) return;
      openFullPlayer(navContext);
    };
    // 登录引导卡点击：app 已被拉起（MainActivity 转发），这里进登录页。
    MediaNotificationService.onWidgetFmOpenLogin = () {
      final nav = appNavigatorKey.currentState;
      if (nav == null) return;
      nav.push(MaterialPageRoute(builder: (_) => const LoginPage()));
    };
  }

  /// 执行小组件按钮命令（iOS 中号 FM 卡：MD3Widget AppIntent 写入 App Group，
  /// 原生回前台经 HomeWidgetService "widgetCommand" 转发到 PlayerProvider，
  /// 再由 fm_ 前缀分流到这里）。
  ///
  /// play_pause / toggle_favorite / open_track 直接复用 [_bindActions] 绑定的
  /// 同一套 MediaNotificationService 回调（Android 通知栏与 iOS 小组件共用），
  /// 保证行为一致；select_station 上游协议带目标档位下标，iOS 命令串不带参数，
  /// 按旧口径「当前档位 +1 循环」。
  Future<void> handleCommand(String action) async {
    switch (action) {
      case 'fm_play_pause':
        MediaNotificationService.onWidgetFmPlayPause?.call();
      case 'fm_toggle_favorite':
        MediaNotificationService.onWidgetFmToggleFavorite?.call();
      case 'fm_select_station':
        final kugou = _kugou;
        if (kugou == null || _fmLoading) return;
        markFmLoading(true);
        try {
          final current = await PersonalFmWidgetActions.restoreStationIndex();
          await PersonalFmWidgetActions.handleSelectStation(
            kugou: kugou,
            index: (current + 1) % kFmStations.length,
          );
        } finally {
          markFmLoading(false);
        }
      case 'fm_open_track_1' || 'fm_open_track_2' || 'fm_open_track_3':
        final kugou = _kugou;
        final player = _player;
        if (kugou == null || player == null) return;
        // 与 [_push] 同一套计算：列表顺序不随播放移动，slot 取播放位之后第 N 首
        final slot = int.parse(action.substring('fm_open_track_'.length)) - 1;
        final songs = kugou.personalFmSongs;
        final playingId = player.currentSong?.id;
        final playingIndex = playingId == null
            ? -1
            : songs.indexWhere((s) => s.hash == playingId);
        final currentIndex = playingIndex >= 0 ? playingIndex : 0;
        final nextTracks = songs.isEmpty
            ? const <KugouSongDetail>[]
            : songs.sublist(currentIndex + 1).take(3).toList();
        if (slot >= nextTracks.length) return;
        MediaNotificationService.onWidgetFmOpenTrack?.call(nextTracks[slot].hash);
    }
  }

  void _scheduleSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      // ignore: discarded_futures
      _push();
    });
  }

  Future<void> _push() async {
    final kugou = _kugou;
    final player = _player;
    final favorites = _favorites;
    if (kugou == null || player == null || favorites == null) return;

    final stationIndex = await PersonalFmWidgetActions.restoreStationIndex();
    final station = kFmStations[stationIndex];

    // 卡片渲染的是播放器当前那一首（列表顺序不随播放移动），与发现页
    // PersonalFmSection.build 同一套计算。
    final songs = kugou.personalFmSongs;
    final playingId = player.currentSong?.id;
    final playingIndex = playingId == null
        ? -1
        : songs.indexWhere((s) => s.hash == playingId);
    final currentIndex = playingIndex >= 0 ? playingIndex : 0;
    final currentTrack = songs.isEmpty ? null : songs[currentIndex];
    final isPlaying = playingIndex >= 0 && player.isPlaying;
    final nextTracks = songs.isEmpty
        ? const <KugouSongDetail>[]
        : songs.sublist(currentIndex + 1).take(3).toList();

    String? nextHash(int i) =>
        i < nextTracks.length ? nextTracks[i].hash : null;
    String? nextCover(int i) =>
        i < nextTracks.length ? nextTracks[i].artworkUri : null;

    final payload = <String, Object?>{
      'isLoggedIn': kugou.isLoggedIn,
      'stationIndex': stationIndex,
      'stationDescription': station.description,
      'isLoading': _fmLoading,
      'isPlaying': isPlaying,
      'isFavorite': currentTrack != null &&
          favorites.isFavorite(currentTrack.hash),
      'title': currentTrack?.songName ?? '点播放，开启你的电台',
      'artist': currentTrack?.artistName ?? '',
      // Intent extras 传不了 null：空串表示「无」，原生侧据此回退占位/缓存
      'coverHash': currentTrack?.hash ?? '',
      'coverUrl': currentTrack?.artworkUri ?? '',
      'nextHash1': nextHash(0) ?? '',
      'nextCover1': nextCover(0) ?? '',
      'nextHash2': nextHash(1) ?? '',
      'nextCover2': nextCover(1) ?? '',
      'nextHash3': nextHash(2) ?? '',
      'nextCover3': nextCover(2) ?? '',
    };

    // 主题色：小部件读不到 Flutter 的动态 ColorScheme，由这里推送当前主题的
    // 12 个色角色。context 不可用（如后台引擎重建早期）时跳过，原生沿用上次缓存。
    // ignore: use_build_context_synchronously
    final navContext = appNavigatorKey.currentContext;
    if (navContext != null) {
      final cs = Theme.of(navContext).colorScheme;
      payload['colors'] = <String, int>{
        'panelBg': cs.surfaceContainerLow.toARGB32(),
        'drawerBg': cs.secondaryContainer.toARGB32(),
        'onDrawer': cs.onSecondaryContainer.toARGB32(),
        'primary': cs.primary.toARGB32(),
        'onPrimary': cs.onPrimary.toARGB32(),
        'surfaceHigh': cs.surfaceContainerHigh.toARGB32(),
        'onSurface': cs.onSurface.toARGB32(),
        'onSurfaceVariant': cs.onSurfaceVariant.toARGB32(),
        'outlineVariant': cs.outlineVariant.toARGB32(),
        'surfaceHighest': cs.surfaceContainerHighest.toARGB32(),
        'primaryContainer': cs.primaryContainer.toARGB32(),
        'onPrimaryContainer': cs.onPrimaryContainer.toARGB32(),
      };
    }

    final encoded = jsonEncode(payload);
    if (encoded == _lastPayload) return;
    _lastPayload = encoded;
    await HomeWidgetService.updateFmWidget(snapshot: payload);

    // 音乐播放器小部件同步主题色（文本/进度仍由 PlayerProvider 推送）。
    // 首次或主题变化时才会因 encoded 变化走到这里。
    final colors = payload['colors'];
    if (colors is Map) {
      // ignore: discarded_futures
      HomeWidgetService.updateMusicWidgetTheme(
        colors: colors.map((k, v) => MapEntry(k.toString(), (v as num).toInt())),
      );
    }
  }
}
