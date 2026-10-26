// 免 Xcode 的 macOS 核心管线验证：加载宿主 dylib → 启动后端 → 命中真实
// 上游（只读搜索与听书元数据）。不代表 UI 层验证，只证明 Rust 核心在
// Apple Silicon 上可用。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:fqapp/src/rust/api.dart' as rust;
import 'package:fqapp/src/rust/frb_generated.dart';

Future<void> main() async {
  const libPath = 'rust/target/release/libfqapi_core.dylib';
  final lib = ExternalLibrary.open(libPath);
  await RustLib.init(externalLibrary: lib);
  stdout.writeln('core version: ${await rust.version()}');

  final dir = await Directory.systemTemp.createTemp('fqprobe');
  final config = File('${dir.path}/config.json');
  // 生产配置原样引用：assets/config/config.json 是端口与开关的唯一来源。
  final asset = File('assets/config/config.json');
  await config.writeAsString(await asset.readAsString());
  final pool = File('${dir.path}/device_pool.json');
  final filter = File('${dir.path}/filter.json');
  final assetPool = File('assets/config/device_pool.example.json');
  await pool.writeAsString(await assetPool.readAsString());
  await filter.writeAsString('[]');
  // 密钥就是 32 字节本身（host 测试同款：hex 字符串的 ASCII）。
  const poolKey = '0123456789abcdef0123456789abcdef';
  await rust.setDevicePoolKey(key: utf8.encode(poolKey));

  final url = await rust.init(
    configPath: config.path,
    poolPath: pool.path,
    filterPath: filter.path,
    runtimeDir: dir.path,
    port: 18921,
    lanShare: false,
    mockUpstreamOrigin: '',
  );
  stdout.writeln('init: $url');
  // 真实上游只读搜索：验证设备池签名、TLS 与响应解密整条链路。
  final response = await rust.request(
    requestId: 'probe-search',
    method: 'GET',
    path: '/api/v1/search',
    query: 'query=%E5%8D%81%E6%97%A5%E7%BB%88%E7%84%89&tab_type=3&offset=0&count=3',
    body: const [],
    timeoutMs: 15000,
  );
  stdout.writeln('search status: ${response.status}');
  final bodyText = utf8.decode(response.body, allowMalformed: true);
  stdout.writeln('search bytes: ${response.body.length}');
  stdout.writeln(
    'head: ${bodyText.length > 160 ? bodyText.substring(0, 160) : bodyText}',
  );
  await rust.shutdown();
  await dir.delete(recursive: true);
  stdout.writeln('OK');
  exit(0);
}
