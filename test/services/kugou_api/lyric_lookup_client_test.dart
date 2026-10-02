import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_endpoints.dart';
import 'package:md3music/services/kugou_api/lyric_lookup_result.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouApiClient client;
  late String originalBaseUrl;
  var searchStatus = HttpStatus.ok;
  Object? searchBody = const {'candidates': <Object>[]};
  Object? lyricBody = const {
    'data': {'decodeContent': '[00:01.00]fixture lyric'},
  };

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    KugouApiClient.markServerReady();
    client = KugouApiClient();
    await client.clearCookies();
    originalBaseUrl = KugouEndpoints.baseUrl;
    client.updateBaseUrl('http://lyric-fixture.invalid');
    client.dio.httpClientAdapter = _LyricFixtureAdapter((options) {
      if (options.path == KugouEndpoints.searchLyric) {
        return (searchStatus, searchBody);
      }
      if (options.path == KugouEndpoints.lyric) {
        return (HttpStatus.ok, lyricBody);
      }
      return (HttpStatus.notFound, const <String, Object?>{});
    });
  });

  tearDownAll(() async {
    client.updateBaseUrl(originalBaseUrl);
    client.dio.close(force: true);
  });

  setUp(() {
    searchStatus = HttpStatus.ok;
    searchBody = const {'candidates': <Object>[]};
    lyricBody = const {
      'data': {'decodeContent': '[00:01.00]fixture lyric'},
    };
  });

  test('成功搜索且候选为空才映射为 notFound', () async {
    final result = await client.getLyricResult('fixture-hash');

    expect(result.status, LyricLookupStatus.notFound);
  });

  test('HTTP服务暂时不可用映射为 transientFailure', () async {
    searchStatus = HttpStatus.serviceUnavailable;
    searchBody = const {'error': 'temporary'};

    final result = await client.getLyricResult('fixture-hash');

    expect(result.status, LyricLookupStatus.transientFailure);
  });

  test('格式错误的候选响应映射为 invalidData', () async {
    searchBody = const {'candidates': 'not-a-list'};

    final result = await client.getLyricResult('fixture-hash');

    expect(result.status, LyricLookupStatus.invalidData);
  });

  test('有效歌词内容映射为 found 并保留正文', () async {
    searchBody = const {
      'candidates': [
        {'id': 'lyric-1', 'accesskey': 'fixture-key'},
      ],
    };

    final result = await client.getLyricResult('fixture-hash');

    expect(result.status, LyricLookupStatus.found);
    expect(result.lyric?.decodedContent, '[00:01.00]fixture lyric');
  });
}

class _LyricFixtureAdapter implements HttpClientAdapter {
  _LyricFixtureAdapter(this.respond);

  final (int, Object?) Function(RequestOptions options) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final (statusCode, body) = respond(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
