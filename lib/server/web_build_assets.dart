import 'dart:io';

import 'package:flutter/services.dart';

/// Copies every asset under [prefix] into a fresh temp directory and returns
/// it.
///
/// The React build (`frontend/`) is emitted to `web_build/` and declared as a
/// Flutter asset, so at runtime it lives inside the app bundle — not next to
/// the process working directory. On a sandboxed macOS build the working
/// directory is the app container (`~/Library/Containers/<bundle-id>/Data`),
/// so a relative `web_build/` path finds nothing and the server 404s. Reading
/// through the [bundle] is the only location that is correct on every platform.
Future<Directory> materializeWebBuild(
  AssetBundle bundle, {
  String prefix = 'web_build/',
}) async {
  final manifest = await AssetManifest.loadFromAssetBundle(bundle);
  final dir = await Directory.systemTemp.createTemp('flutter_wanxiang_web_');

  for (final key in manifest.listAssets()) {
    if (!key.startsWith(prefix)) continue;
    final relative = key.substring(prefix.length);
    if (relative.isEmpty) continue;

    final file = File('${dir.path}/$relative');
    await file.parent.create(recursive: true);
    final data = await bundle.load(key);
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }
  return dir;
}

/// Writes one bundled [key] asset to a fresh temp file and returns it.
///
/// A pure-Dart consumer (e.g. the pipeline server / an ffmpeg subprocess)
/// cannot read Flutter assets, so a packaged resource such as the presenter
/// image is materialized to disk first.
Future<File> materializeAssetFile(
  AssetBundle bundle, {
  required String key,
  required String suffix,
}) async {
  final data = await bundle.load(key);
  final dir = await Directory.systemTemp.createTemp('flutter_wanxiang_asset_');
  final file = File('${dir.path}/asset$suffix');
  await file.writeAsBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
  return file;
}
