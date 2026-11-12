// 回归：上游（hhplayer.com 等）对 m3u8 回 gzip 体时，代理曾把压缩字节
// 当 UTF-8 文本改写，浏览器拿到的播放列表全是乱码分片地址。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:kazumi_web/proxy/proxy_session_store.dart';
import 'package:kazumi_web/proxy/video_proxy_handler.dart';

const _playlist = '#EXTM3U\n'
    '#EXT-X-VERSION:3\n'
    '#EXT-X-TARGETDURATION:10\n'
    '#EXT-X-MEDIA-SEQUENCE:0\n'
    '#EXTINF:4.5,\n'
    'https://cdn.example.com/seg0.ts\n'
    '#EXTINF:3.5,\n'
    'seg1.ts\n'
    '#EXT-X-ENDLIST\n';

void main() {
  group('decodeContentEncoding', () {
    final raw = utf8.encode(_playlist);

    test('gzip by header', () {
      expect(VideoProxyHandler.decodeContentEncoding(gzip.encode(raw), 'gzip'),
          raw);
    });

    test('gzip by magic bytes when header is missing', () {
      expect(VideoProxyHandler.decodeContentEncoding(gzip.encode(raw), null),
          raw);
    });

    test('deflate', () {
      expect(
          VideoProxyHandler.decodeContentEncoding(zlib.encode(raw), 'deflate'),
          raw);
    });

    test('identity and broken bodies pass through unchanged', () {
      expect(VideoProxyHandler.decodeContentEncoding(raw, null), raw);
      final broken = [0x1f, 0x8b, 0x00, 0x01];
      expect(VideoProxyHandler.decodeContentEncoding(broken, 'gzip'), broken);
    });
  });

  group('m3u8 relay', () {
    late HttpServer upstream;
    late HttpServer proxyServer;
    late VideoProxyHandler handler;
    late String token;
    String? seenAcceptEncoding;

    setUp(() async {
      seenAcceptEncoding = null;
      // 桩上游无视 accept-encoding，总是回 gzip（真实上游的最坏情况）
      upstream = await HttpServer.bind('127.0.0.1', 0);
      upstream.autoCompress = false;
      upstream.listen((req) async {
        seenAcceptEncoding = req.headers.value('accept-encoding');
        req.response.headers
          ..set('content-type', 'application/vnd.apple.mpegurl')
          ..set('content-encoding', 'gzip');
        req.response.add(gzip.encode(utf8.encode(_playlist)));
        await req.response.close();
      });

      final store = ProxySessionStore();
      token = store.register(ProxySession(
        originalUrl: 'http://127.0.0.1:${upstream.port}/playlist/index.m3u8',
        referer: '',
        userAgent: 'test-agent',
        pluginName: 'test',
        createdAt: DateTime.now(),
      ));
      handler = VideoProxyHandler(sessionStore: store);
      proxyServer = await shelf_io.serve(
        (shelf.Request request) => handler.handle(request, token),
        '127.0.0.1',
        0,
      );
    });

    tearDown(() async {
      handler.close();
      await proxyServer.close(force: true);
      await upstream.close(force: true);
    });

    test('asks upstream for identity and rewrites a gzip playlist', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final req = await client.get('127.0.0.1', proxyServer.port, '/');
      final res = await req.close().timeout(const Duration(seconds: 5));
      final body = await utf8.decodeStream(res);

      expect(seenAcceptEncoding, 'identity');
      expect(res.statusCode, HttpStatus.ok);
      expect(body, startsWith('#EXTM3U'));

      final uris = const LineSplitter()
          .convert(body)
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();
      expect(uris, hasLength(2));
      final decoded = uris.map((u) {
        final encoded = u.split('/').last;
        return utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
      }).toList();
      expect(decoded, [
        'https://cdn.example.com/seg0.ts',
        'http://127.0.0.1:${upstream.port}/playlist/seg1.ts',
      ]);
    });
  });
}
