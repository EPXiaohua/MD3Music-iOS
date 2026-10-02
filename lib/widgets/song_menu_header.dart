import 'package:material_ui/material_ui.dart';

import '../data/models/song.dart';
import 'smart_artwork_image.dart';

/// 歌曲更多菜单的头部：左侧圆角矩形封面（约头部高度的 70%），
/// 右侧三行文字：歌名 / 歌手 / 专辑。
class SongMenuHeader extends StatelessWidget {
  final Song song;

  const SongMenuHeader({super.key, required this.song});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Row(
        children: [
          // 左侧圆角矩形封面，84×84（头部视觉主体）
          SmartArtworkImage(
            artworkUri: song.artworkUri,
            fallbackFilePath: song.localPath,
            songId: song.id,
            size: 84,
            borderRadius: 16,
          ),
          const SizedBox(width: 16),
          // 右侧文字信息：歌名 / 歌手 / 专辑
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  song.album.isEmpty ? '未知专辑' : song.album,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
