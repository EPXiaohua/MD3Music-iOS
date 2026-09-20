import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:http/http.dart' as http;

/// 音频格式展示工具：源文件编码名、文件头位深解析、Media3 编码常量与格式化。
///
/// 供 USB 独占格式链（源文件/播放流/DAC 端点）与歌曲信息页共用，保证两处展示一致。
class AudioFormatUtils {
  AudioFormatUtils._();

  /// Media3 编码常量 → 位深（bit）。
  static int encodingBits(int encoding) {
    switch (encoding) {
      case 4: // C.ENCODING_PCM_FLOAT
        return 32;
      case 2: // C.ENCODING_PCM_16BIT
        return 16;
      case 0x15: // C.ENCODING_PCM_24BIT
        return 24;
      case 0x16: // C.ENCODING_PCM_32BIT
        return 32;
      default:
        return 16;
    }
  }

  /// 采样率格式化：48000 → "48 kHz"，44100 → "44.1 kHz"；<=0 返回 "—"。
  static String formatRate(int rate) {
    if (rate <= 0) return '—';
    if (rate % 1000 == 0) return '${rate ~/ 1000} kHz';
    return '${(rate / 1000).toStringAsFixed(1)} kHz';
  }

  /// 声道数格式化：1 → "1 ch"，2 → "2 ch"，与参考图风格一致；<=0 返回 "—"。
  static String formatCh(int ch) {
    if (ch <= 0) return '—';
    return '$ch ch';
  }

  /// 位深格式化：24 → "24-bit"；<=0 返回 "—"。
  static String formatBits(int bits) {
    if (bits <= 0) return '—';
    return '$bits-bit';
  }

  /// 有损编码集合（此类格式源文件行不展示位深，位深概念仅存在于解码后 PCM）。
  static const Set<String> lossyCodecs = {'MP3', 'AAC', 'OPUS', 'OGG', 'AMR'};

  /// sampleMimeType（Media3）→ 编码短名（FLAC/MP3/AAC/…）。无法识别返回 null。
  /// [codecs] 为 Format.codecs 字符串，用于 OGG 容器内区分 Opus/Vorbis。
  static String? codecLabelFromMime(String? mime, {String? codecs}) {
    if (mime == null || mime.isEmpty) return null;
    final m = mime.toLowerCase();
    final cs = (codecs ?? '').toLowerCase();
    if (m.contains('flac')) return 'FLAC';
    if (m.contains('mpeg') || m.contains('mp3')) return 'MP3';
    if (m.contains('mp4a') || m.contains('aac')) return 'AAC';
    if (m.contains('opus')) return 'OPUS';
    if (m.contains('vorbis') || m == 'audio/ogg' || m.contains('application/ogg')) {
      return cs.contains('opus') ? 'OPUS' : 'OGG';
    }
    if (m.contains('alac')) return 'ALAC';
    if (m.contains('ape') || m.contains('monkey')) return 'APE';
    if (m.contains('wav') || m.contains('wave') || m.contains('pcm')) return 'WAV';
    if (m.contains('ac3') || m.contains('e-ac3') || m.contains('ec3')) return 'AC3';
    if (m.contains('amr')) return 'AMR';
    if (m.contains('dff') || m.contains('dsd') || m.contains('dsf')) return 'DSD';
    if (m.contains('mqa')) return 'MQA';
    return null;
  }

  /// 从文件路径/URL 扩展名推断编码短名（mime 缺失时兜底）。无法识别返回 null。
  static String? codecLabelFromPath(String? url, String? localPath) {
    String? ext;
    for (final p in [localPath, url]) {
      if (p == null || p.isEmpty) continue;
      final q = p.split('?').first;
      final idx = q.lastIndexOf('.');
      if (idx >= 0 && idx < q.length - 1) {
        ext = q.substring(idx + 1).toLowerCase();
        break;
      }
    }
    if (ext == null || ext.isEmpty) return null;
    const map = {
      'flac': 'FLAC',
      'mp3': 'MP3',
      'm4a': 'AAC',
      'aac': 'AAC',
      'opus': 'OPUS',
      'ogg': 'OGG',
      'oga': 'OGG',
      'wav': 'WAV',
      'ape': 'APE',
      'alac': 'ALAC',
      'ac3': 'AC3',
      'amr': 'AMR',
      'dff': 'DSD',
      'dsf': 'DSD',
      'dsd': 'DSD',
    };
    return map[ext] ?? ext.toUpperCase();
  }

  /// 把应用内的路径形态解析为磁盘文件：裸路径 / `file://` / `local://`。
  /// 本地歌曲的 artwork/播放地址常用 `local://<绝对路径>` 形态（缺省盘符斜杠需补全）。
  static Future<File?> _resolveLocalFile(String p) async {
    if (p.isEmpty) return null;
    final direct = File(p);
    if (await direct.exists()) return direct;
    final uri = Uri.tryParse(p);
    if (uri != null && uri.scheme == 'file') {
      final f = File(uri.toFilePath());
      if (await f.exists()) return f;
    }
    if (p.startsWith('local://')) {
      final path = p.substring('local://'.length);
      final f = File(path.startsWith('/') ? path : '/$path');
      if (await f.exists()) return f;
    }
    return null;
  }

  /// 仅供单元测试（test/core/utils/audio_format_utils_test.dart）调用：
  /// WAV 位深解析（RIFF chunk 遍历）。生产路径请走 [parseAudioBitDepth]。
  static int? parseWavBitsForTest(Uint8List head) =>
      _parseWavBitsPerSample(head);

  /// WAV fmt chunk → (sampleRate, channels, bitsPerSample)。
  /// 沿 RIFF chunk 链定位 "fmt "，兼容 fmt 前有 JUNK/LIST/bext 等非规范 chunk、
  /// fmt 18/40 字节（WAVE_FORMAT_EXTENSIBLE）与 IEEE float（formatTag=3）布局。
  /// [head] 为文件头前若干字节（建议 ≥4KB）。找不到 fmt 返回 null。
  static (int, int, int)? _parseWavFmt(Uint8List head) {
    if (head.length < 12) return null;
    // WAVE / WAVE(=RF64 变体)：offset 8..11 应为 "WAVE"
    if (head[8] != 0x57 || head[9] != 0x41 || head[10] != 0x56 || head[11] != 0x45) {
      return null;
    }
    var pos = 12;
    while (pos + 8 <= head.length) {
      final id = String.fromCharCodes([
        head[pos], head[pos + 1], head[pos + 2], head[pos + 3],
      ]);
      final size = (head[pos + 4] & 0xFF) |
          ((head[pos + 5] & 0xFF) << 8) |
          ((head[pos + 6] & 0xFF) << 16) |
          ((head[pos + 7] & 0xFF) << 24);
      final body = pos + 8;
      if (id == 'fmt ') {
        if (body + 16 > head.length) return null;
        final channels = (head[body + 2] & 0xFF) | ((head[body + 3] & 0xFF) << 8);
        final rate = (head[body + 4] & 0xFF) |
            ((head[body + 5] & 0xFF) << 8) |
            ((head[body + 6] & 0xFF) << 16) |
            ((head[body + 7] & 0xFF) << 24);
        final bits = (head[body + 14] & 0xFF) | ((head[body + 15] & 0xFF) << 8);
        return (rate, channels, (bits > 0 && bits <= 32) ? bits : 0);
      }
      if (size <= 0) return null; // 非法 chunk，放弃
      // chunk 按 2 字节对齐（奇数长度补 1）
      pos = body + size + (size & 1);
    }
    return null;
  }

  /// WAV/RF64 位深解析（供 [parseAudioBitDepth] 与单元测试使用）。
  static int? _parseWavBitsPerSample(Uint8List head) {
    final fmt = _parseWavFmt(head);
    return (fmt != null && fmt.$3 > 0) ? fmt.$3 : null;
  }

  /// 获取音频文件头字节：本地文件（裸路径 / file:// / local://）直读，
  /// 网络 URL 用 Range 请求。失败返回 null。
  static Future<Uint8List?> _fetchAudioHead(
      String? url, String? localPath, int bytes) async {
    // 路径形态兼容：裸路径 / file:// / local://（本地歌曲常用形态）
    final localFile = await _resolveLocalFile(localPath ?? '') ??
        await _resolveLocalFile(url ?? '');
    if (localFile != null) {
      final raf = await localFile.open();
      try {
        return await raf.read(bytes);
      } finally {
        await raf.close();
      }
    }
    if (url != null &&
        (url.startsWith('http://') || url.startsWith('https://'))) {
      final resp = await http
          .get(Uri.parse(url), headers: {'Range': 'bytes=0-${bytes - 1}'})
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      return resp.bodyBytes;
    }
    return null;
  }

  /// 解析音频文件头（FLAC STREAMINFO / WAV fmt chunk）获取原始位深。
  /// 本地文件直接读，网络 URL 用 Range 请求前 4KB。解析失败返回 null。
  static Future<int?> parseAudioBitDepth(String? url, String? localPath) async {
    try {
      final head = await _fetchAudioHead(url, localPath, 4096);
      if (head == null || head.length < 32) return null;

      // FLAC: "fLaC" + STREAMINFO 块，采样参数在 offset 8+10=18（8 字节）
      if (head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43) {
        const off = 18;
        if (head.length < off + 4) return null;
        final bps = (((head[off + 2] & 0x01) << 4) | ((head[off + 3] >> 4) & 0x0F)) + 1;
        if (bps > 0 && bps <= 32) return bps;
      }

      // WAV/RF64: 走 RIFF chunk 链定位 "fmt "（2026-09-14 修复：旧实现硬编码
      // bitsPerSample@34，仅对「RIFF 后紧跟 16 字节 fmt」的规范布局成立；
      // fmt 前有 JUNK/LIST/bext、fmt 为 18/40 字节（WAVE_FORMAT_EXTENSIBLE）、
      // 或 IEEE float(tag=3) 的实际产物都会解析失败 → 源文件行缺位深）。
      final magic = String.fromCharCodes([head[0], head[1], head[2], head[3]]);
      if (magic == 'RIFF' || magic == 'RF64') {
        return _parseWavBitsPerSample(head);
      }
    } catch (_) {
      // 网络/文件解析失败静默处理
    }
    return null;
  }

  /// 解析歌曲源格式：采样率/声道/位深/码率（kbps），无法解析的维度为 null。
  ///
  /// 平台无关兜底：iOS 端无 ExoPlayer TrackGroup 与原生 USB 状态，歌曲信息页
  /// 与 USB 格式链「源文件」行在拿不到播放器格式时用它。网络歌曲 Range 取头
  /// 64KB（跳过较大 ID3v2 后仍能命中 MP3 首帧），本地文件再用
  /// audio_metadata_reader 补漏（M4A/AAC 采样率、部分码率）。
  static Future<Map<String, int?>> parseAudioSourceInfo(
      String? url, String? localPath) async {
    final info = <String, int?>{
      'sampleRate': null,
      'channels': null,
      'bits': null,
      'bitrate': null,
    };
    try {
      final head = await _fetchAudioHead(url, localPath, 65536);
      if (head != null && head.length >= 12) {
        final magic = String.fromCharCodes([head[0], head[1], head[2], head[3]]);
        if (magic == 'fLaC' && head.length >= 26) {
          // STREAMINFO：sampleRate 20bit @18、channels 3bit @20[1:3]、bps 5bit
          final sr = (head[18] << 12) | (head[19] << 4) | (head[20] >> 4);
          final ch = ((head[20] >> 1) & 0x07) + 1;
          final bps = (((head[20] & 0x01) << 4) | ((head[21] >> 4) & 0x0F)) + 1;
          if (sr > 0 && sr < 1000000) info['sampleRate'] = sr;
          if (ch > 0 && ch <= 8) info['channels'] = ch;
          if (bps > 0 && bps <= 32) info['bits'] = bps;
        } else if (magic == 'RIFF' || magic == 'RF64') {
          final fmt = _parseWavFmt(head);
          if (fmt != null) {
            if (fmt.$1 > 0 && fmt.$1 < 1000000) info['sampleRate'] = fmt.$1;
            if (fmt.$2 > 0 && fmt.$2 <= 8) info['channels'] = fmt.$2;
            if (fmt.$3 > 0) info['bits'] = fmt.$3;
          }
        } else if (magic == 'OggS' && head.length >= 44) {
          final magic28 = String.fromCharCodes(head.sublist(28, 36));
          if (magic28 == 'OpusHead') {
            // Opus 恒解码到 48kHz；声道 @37
            info['sampleRate'] = 48000;
            if (head[37] > 0 && head[37] <= 8) info['channels'] = head[37];
          } else if (head[28] == 0x01) {
            // vorbis identification header：channels @39、sampleRate LE @40
            if (head[39] > 0 && head[39] <= 8) info['channels'] = head[39];
            final sr = (head[40] & 0xFF) |
                ((head[41] & 0xFF) << 8) |
                ((head[42] & 0xFF) << 16) |
                ((head[43] & 0xFF) << 24);
            if (sr > 0 && sr < 1000000) info['sampleRate'] = sr;
          }
        } else {
          // ftyp（MP4/M4A）box size 占 0..3，标志在 4..7；手动解析复杂，
          // 采样率留给下方本地文件补漏，不走 MP3 同步字扫描以免误判
          final magic4 = String.fromCharCodes(
              [head[4], head[5], head[6], head[7]]);
          if (magic4 != 'ftyp') _parseMp3Frame(head, info);
        }
      }

      // 本地文件补漏（audio_metadata_reader：M4A/AAC 采样率、MP3 码率等）
      final f = await _resolveLocalFile(localPath ?? '') ??
          await _resolveLocalFile(url ?? '');
      if (f != null) {
        try {
          final m = amr.readMetadata(f, getImage: false);
          final sr = m.sampleRate;
          if (info['sampleRate'] == null && sr != null && sr > 0) {
            info['sampleRate'] = sr;
          }
          final br = m.bitrate;
          if (info['bitrate'] == null && br != null && br > 0) {
            info['bitrate'] = br;
          }
        } catch (_) {}
      }
    } catch (_) {
      // 网络/文件解析失败静默处理
    }
    return info;
  }

  /// MP3 frame header 解析：跳过 ID3v2，扫描 0xFFE0 同步字。
  /// 结果直接写入 [info]（sampleRate/channels/bitrate(kbps)）。
  static void _parseMp3Frame(Uint8List head, Map<String, int?> info) {
    var pos = 0;
    if (head.length >= 10 &&
        head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
      // "ID3"：v2 标签长度为 syncsafe 编码 @6..9
      final size = ((head[6] & 0x7F) << 21) |
          ((head[7] & 0x7F) << 14) |
          ((head[8] & 0x7F) << 7) |
          (head[9] & 0x7F);
      pos = 10 + size;
    }
    // Layer3 码率表（kbps）：MPEG1 与 MPEG2/2.5
    const br1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
    const br2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
    const srTab = <int, List<int>>{
      3: [44100, 48000, 32000], // MPEG1
      2: [22050, 24000, 16000], // MPEG2
      0: [11025, 12000, 8000], // MPEG2.5
    };
    while (pos >= 0 && pos + 4 <= head.length) {
      if (head[pos] == 0xFF && (head[pos + 1] & 0xE0) == 0xE0) {
        final ver = (head[pos + 1] >> 3) & 0x03; // 3=MPEG1 2=MPEG2 0=MPEG2.5
        final layer = (head[pos + 1] >> 1) & 0x03; // 1=Layer3
        final brIdx = (head[pos + 2] >> 4) & 0x0F;
        final srIdx = (head[pos + 2] >> 2) & 0x03;
        final mode = (head[pos + 3] >> 6) & 0x03; // 3=单声道
        final srList = srTab[ver];
        if (layer == 1 && srList != null && srIdx < 3 &&
            brIdx >= 1 && brIdx <= 14) {
          info['sampleRate'] ??= srList[srIdx];
          info['channels'] ??= mode == 3 ? 1 : 2;
          final br = (ver == 3 ? br1 : br2)[brIdx];
          if (br > 0) info['bitrate'] ??= br;
          return;
        }
      }
      pos++;
    }
  }
}
