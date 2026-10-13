import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_wanxiang/server/web_build_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('copies the bundled web build into a readable temp dir', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys = manifest.listAssets().where((k) => k.startsWith('web_build/'));
    if (keys.isEmpty) {
      markTestSkipped(
        'web_build/ is not bundled; run `npm run build` in frontend/ first',
      );
      return;
    }

    final dir = await materializeWebBuild(rootBundle);
    addTearDown(() => dir.deleteSync(recursive: true));

    final index = File('${dir.path}/index.html');
    expect(index.existsSync(), isTrue);
    expect(index.readAsStringSync(), contains('<div id="root">'));

    // The API server references hashed bundles under web_build/assets/, so
    // those nested files must be materialized too (pubspec lists that dir
    // separately — Flutter asset directory entries are not recursive).
    final assets = Directory('${dir.path}/assets');
    expect(assets.existsSync(), isTrue);
    final names = assets.listSync().map((e) => e.path).toList();
    expect(names.any((p) => p.endsWith('.js')), isTrue);
    expect(names.any((p) => p.endsWith('.css')), isTrue);
  });
}
