// 终验：同进程内 开代理会话 + media_kit 播放（代理 session 存活于本进程）
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';

Future<void> main(List<String> args) async {
  final srcUrl = args[0];
  final keyHex = args[1];
  final frw = Directory(
    '/Users/raven/tomato/fqapp/build/macos/Build/Products/Release/fqapp.app/Contents/Frameworks',
  );
  // 裸进程没有主程序的 LC_RPATH：先按依赖顺序加载所有依赖 framework。
  final order = [
    'Xml2', 'Dav1d', 'Mbedcrypto', 'Mbedx509', 'Mbedtls',
    'Fribidi', 'Harfbuzz', 'Png16', 'Freetype',
    'Avutil', 'Swresample', 'Avcodec', 'Avformat', 'Avfilter', 'Swscale',
    'Ass', 'Uchardet',
  ];
  for (final name in order) {
    final bin = File(
      '${frw.path}/$name.framework/Versions/A/$name',
    );
    if (bin.existsSync()) {
      try {
        DynamicLibrary.open(bin.path);
      } catch (_) {}
    }
  }
  MediaKit.ensureInitialized(
    libmpv: '${frw.path}/Mpv.framework/Versions/A/Mpv',
  );
  // 打开解密代理会话（本进程内，线程保活）
  final lib = DynamicLibrary.open(
    '/Users/raven/tomato/fqapp/rust/target/release/libfqapi_core.dylib',
  );
  final mediaOpen = lib
      .lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Utf8>)>('fq_desktop_media_open');
  final req = jsonEncode({'url': srcUrl, 'key': keyHex}).toNativeUtf8();
  final respPtr = mediaOpen(req);
  final resp = jsonDecode(respPtr.toDartString()) as Map<String, dynamic>;
  calloc.free(req);
  if (resp.containsKey('error')) throw StateError('proxy: ${resp['error']}');
  final proxyUrl = resp['url'] as String;
  stdout.writeln('proxy ready: $proxyUrl');

  final player = Player();
  await player.open(Media(proxyUrl), play: true);
  await Future<void>.delayed(const Duration(seconds: 5));
  stdout.writeln(
    'duration=${player.state.duration} position=${player.state.position} '
    'playing=${player.state.playing}',
  );
  await player.dispose();
  exit(0);
}
