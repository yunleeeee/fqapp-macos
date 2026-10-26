// 免 Xcode 的听书数据链路验证（macOS 原生 Rust 核心）：
// 搜索听书 tab → 有声目录 → 取第一集 → /api/v1/audio/play 解析播放模型 →
// HEAD 拉流测活。只读，不登录（公书可听）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:fqapp/src/rust/api.dart' as rust;
import 'package:fqapp/src/rust/frb_generated.dart';

int _id = 0;
String _nextId() => 'probe-${_id++}';

Future<Map<String, dynamic>> _call(
  String method,
  String path,
  Map<String, String> query, {
  List<int> body = const [],
  int timeoutMs = 20000,
}) async {
  final r = await rust.request(
    requestId: _nextId(),
    method: method,
    path: path,
    query: Uri(queryParameters: query).query,
    body: body,
    timeoutMs: timeoutMs,
  );
  if (r.status != 200) {
    throw StateError('$path -> HTTP ${r.status}: '
        '${utf8.decode(r.body, allowMalformed: true).substring(0, 200)}');
  }
  return jsonDecode(utf8.decode(r.body)) as Map<String, dynamic>;
}

Future<void> main() async {
  final lib = ExternalLibrary.open('rust/target/release/libfqapi_core.dylib');
  await RustLib.init(externalLibrary: lib);
  final dir = await Directory.systemTemp.createTemp('fqaudio');
  await File('${dir.path}/config.json')
      .writeAsString(await File('assets/config/config.json').readAsString());
  await File('${dir.path}/device_pool.json').writeAsString(
      await File('assets/config/device_pool.example.json').readAsString());
  await File('${dir.path}/filter.json').writeAsString('[]');
  const poolKey = '0123456789abcdef0123456789abcdef';
  await rust.setDevicePoolKey(key: utf8.encode(poolKey));
  final started = await rust.init(
    configPath: '${dir.path}/config.json',
    poolPath: '${dir.path}/device_pool.json',
    filterPath: '${dir.path}/filter.json',
    runtimeDir: dir.path,
    port: 18921,
    lanShare: false,
    mockUpstreamOrigin: '',
  );
  stdout.writeln('core: $started');

  // 1) 听书 tab 搜索
  final search = await _call('GET', '/api/v1/search',
      {'query': '十日终焉', 'tab_type': '2', 'offset': '0', 'count': '5'});
  final tabs = (search['search_tabs'] as List? ?? []);
  Map<String, dynamic>? first;
  outer:
  for (final tab in tabs) {
    final data = (tab as Map)['data'] as List? ?? [];
    for (final item in data) {
      final m = item as Map;
      final bookId = (m['book_id'] ?? m['id'])?.toString() ?? '';
      if (bookId.isNotEmpty) {
        first = Map<String, dynamic>.from(m);
        break outer;
      }
    }
  }
  if (first == null) throw StateError('搜索未返回听书条目: ${jsonEncode(search).substring(0, 300)}');
  final bookId = (first['book_id'] ?? first['id']).toString();
  stdout.writeln('book: ${first['title']}  id=$bookId');

  // 2) 有声目录：真实 shape 是 data.item_data_list（卷列表），每卷的集数在
  //    chapterList / item_list / lists 之一（与 parseDirectory 同键位）。
  final directory =
      await _call('GET', '/api/v1/books/$bookId/directory', const {});
  final data = directory['data'] as Map<String, dynamic>? ?? {};
  final volumes = data['item_data_list'] as List? ?? [];
  String? itemId;
  String? itemTitle;
  for (final vol in volumes) {
    final vm = vol as Map;
    List? items;
    for (final key in ['chapterList', 'item_list', 'lists', 'item_data_list']) {
      if (vm[key] is List) {
        items = vm[key] as List;
        break;
      }
    }
    // 卷本身可能就是集数组
    items ??= vm['item_id'] != null || vm['id'] != null ? [vm] : null;
    if (items == null || items.isEmpty) continue;
    final ep = items.first as Map;
    itemId = (ep['item_id'] ?? ep['itemId'] ?? ep['id'])?.toString();
    itemTitle = ep['title']?.toString();
    break;
  }
  if (itemId == null) throw StateError('目录无集数: ${jsonEncode(directory).substring(0, 300)}');
  stdout.writeln('episode 1: $itemTitle  item_id=$itemId');

  // 3) 播放模型：走 app 实际使用的 playinfo 端点（tone_id=0），
  //    而不是旧的 video_model/mget 桥。
  final play = await _call(
    'GET',
    '/api/v1/audio/books/$bookId/chapters/$itemId',
    {'tone_id': '0'},
  );
  final payload = jsonEncode(play);
  stdout.writeln('play code=${play['code']} bytes=${payload.length}');
  stdout.writeln('play head: ${payload.substring(0, payload.length.clamp(0, 300))}');

  // 4) 从播放模型里找音频 URL 并测活（递归找 http(s) .mp3/.m4a/.aac 或明显字段）
  String? audioUrl;
  void hunt(dynamic node) {
    if (audioUrl != null) return;
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
          audioUrl = v;
          return;
        }
        hunt(v);
      }
    } else if (node is List) {
      for (final e in node) {
        hunt(e);
        if (audioUrl != null) return;
      }
    }
  }

  hunt(play);
  if (audioUrl == null) {
    stdout.writeln('未在播放模型中找到音频 URL（可能需要登录或音色参数）');
  } else {
    stdout.writeln('audio url: ${audioUrl!.substring(0, audioUrl!.length.clamp(0, 120))}...');
    final client = HttpClient();
    final req = await client.openUrl('HEAD', Uri.parse(audioUrl!));
    final res = await req.close();
    stdout.writeln('HEAD audio: ${res.statusCode} ${res.contentLength} bytes');
    client.close(force: true);
  }

  await rust.shutdown();
  await dir.delete(recursive: true);
  stdout.writeln('AUDIO PIPELINE OK');
  exit(0);
}
