// 听书音频真机流验证（免 Xcode）：跑音频探针拿新鲜 URL → media_kit(libmpv)
// 实际加载 → 读元数据/时长 → 播放 3 秒验证音频管线出帧。
// 注意：直接 dart run 即可，因为 media_kit 的 NativePlayer 在纯 Dart VM 里
// 也走同一套 libmpv 动态库（Frameworks 缺失时报错也算有效结论）。
import 'dart:convert';
import 'dart:io';

import 'package:fqapp/src/rust/api.dart' as rust;
import 'package:fqapp/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:media_kit/media_kit.dart';

int _id = 0;

Future<Map<String, dynamic>> _call(
  String method,
  String path,
  Map<String, String> query, {
  List<int> body = const [],
  int timeoutMs = 20000,
}) async {
  final r = await rust.request(
    requestId: 'probe-${_id++}',
    method: method,
    path: path,
    query: Uri(queryParameters: query).query,
    body: body,
    timeoutMs: timeoutMs,
  );
  if (r.status != 200) {
    throw StateError('$path -> HTTP ${r.status}');
  }
  return jsonDecode(utf8.decode(r.body)) as Map<String, dynamic>;
}

String? _audioUrl;
void _hunt(dynamic node) {
  if (_audioUrl != null || node == null) return;
  if (node is Map) {
    for (final e in node.entries) {
      final k = e.key.toString().toLowerCase();
      final v = e.value;
      if (v is String &&
          v.startsWith('http') &&
          (k.contains('url') ||
              v.contains('.mp3') ||
              v.contains('.m4a') ||
              v.contains('.aac'))) {
        _audioUrl = v;
        return;
      }
      _hunt(v);
      if (_audioUrl != null) return;
    }
  } else if (node is List) {
    for (final e in node) {
      _hunt(e);
      if (_audioUrl != null) return;
    }
  }
}

Future<void> main() async {
  final lib = ExternalLibrary.open('rust/target/release/libfqapi_core.dylib');
  await RustLib.init(externalLibrary: lib);
  final dir = await Directory.systemTemp.createTemp('fqplay');
  await File('${dir.path}/config.json')
      .writeAsString(await File('assets/config/config.json').readAsString());
  await File('${dir.path}/device_pool.json').writeAsString(
      await File('assets/config/device_pool.example.json').readAsString());
  await File('${dir.path}/filter.json').writeAsString('[]');
  await rust.setDevicePoolKey(key: utf8.encode('0123456789abcdef0123456789abcdef'));
  await rust.init(
    configPath: '${dir.path}/config.json',
    poolPath: '${dir.path}/device_pool.json',
    filterPath: '${dir.path}/filter.json',
    runtimeDir: dir.path,
    port: 18921,
    lanShare: false,
    mockUpstreamOrigin: '',
  );
  // 目录解析与 macos_audio_probe 同键位（卷内集数在 chapterList/item_list/lists）。
  const bookId = '7281195245084691518';
  final search = await _call('GET', '/api/v1/books/$bookId/directory', const {});
  final data = search['data'] as Map<String, dynamic>? ?? {};
  String itemId = '';
  volumes:
  for (final vol in (data['item_data_list'] as List? ?? [])) {
    final vm = vol as Map;
    for (final key in ['chapterList', 'item_list', 'lists', 'item_data_list']) {
      final items = vm[key] as List?;
      if (items != null && items.isNotEmpty) {
        final ep = items.first as Map;
        itemId = (ep['item_id'] ?? ep['itemId'] ?? ep['id'] ?? '').toString();
        if (itemId.isNotEmpty) break volumes;
      }
    }
    // 卷本身可能是集
    final direct = (vm['item_id'] ?? vm['itemId'] ?? vm['id'])?.toString();
    if (direct != null && direct.isNotEmpty) {
      itemId = direct;
      break volumes;
    }
  }
  if (itemId.isEmpty) throw StateError('目录无集数');
  final play = await _call('GET', '/api/v1/audio/books/$bookId/chapters/$itemId',
      {'tone_id': '0'});
  _hunt(play);
  if (_audioUrl == null) throw StateError('无音频 URL');
  stdout.writeln('url ok: ${_audioUrl!.substring(0, 60)}...');

  // —— media_kit / libmpv 实际加载 ——
  // 纯 Dart VM 验证：DYLD_FALLBACK 或 LIBMPV_LIBRARY_PATH 指向解包后的
  // Mpv.framework（正式 .app 内由 CocoaPods 放进 Contents/Frameworks）。
  MediaKit.ensureInitialized(
    libmpv:
        '${Directory.current.path}/.probe_frameworks/Frw/Mpv.framework/Mpv',
  );
  final player = Player();
  await player.open(Media(_audioUrl!), play: true);
  final completer = Future<void>.delayed(const Duration(seconds: 4));
  await completer;
  var error = false;
  final errorSub = player.stream.error.listen((_) => error = true);
  final duration = player.state.duration;
  final position = player.state.position;
  final playing = player.state.playing;
  final completed = player.state.completed;
  stdout.writeln(
    'media_kit: duration=$duration position=$position playing=$playing '
    'completed=$completed error=$error',
  );
  await errorSub.cancel();
  await player.dispose();
  await rust.shutdown();
  await dir.delete(recursive: true);
  if (duration == Duration.zero && !playing) {
    stdout.writeln('PLAYBACK NOT CONFIRMED（可能 libmpv 动态库缺失或 URL 过期）');
    exit(2);
  }
  stdout.writeln('PLAYBACK OK 🎧');
  exit(0);
}
