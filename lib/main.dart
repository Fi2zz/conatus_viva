import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'server/start.dart';
import 'server/web_build_assets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = await _resolveEnv();
  final staticDir = await materializeWebBuild(rootBundle);
  final avatarImage = await materializeAssetFile(
    rootBundle,
    key: 'assets/images/speaker_avatar.jpg',
    suffix: '.jpg',
  );
  final url = await startPipelineServer(
    staticDir: staticDir.path,
    avatarImage: avatarImage,
    env: env,
  );
  runApp(SpeakerApp(serverUrl: url));
}

/// Process environment plus an optional bundled `.env`.
///
/// Exported variables win; the bundled `.env` supplies `DASHSCOPE_API_KEY` when
/// the app is launched from Finder (no shell environment). A missing `.env` is
/// fine — the merge just falls back to the process environment.
Future<Map<String, String>> _resolveEnv() async {
  try {
    await dotenv.load(fileName: '.env', mergeWith: const <String, String>{});
  } catch (_) {
    // .env is optional.
  }
  return <String, String>{...Platform.environment, ...dotenv.env};
}

class SpeakerApp extends StatelessWidget {
  const SpeakerApp({super.key, required this.serverUrl});

  final String serverUrl;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Viva',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: WebViewPage(url: serverUrl),
    );
  }
}

class WebViewPage extends StatefulWidget {
  const WebViewPage({super.key, required this.url});

  final String url;

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  late final WebViewController controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    debugPrint('WebView loading: ${widget.url}');
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            debugPrint('Page started: $url');
            setState(() => _loading = true);
          },
          onPageFinished: (url) {
            debugPrint('Page finished: $url');
            setState(() {
              _loading = false;
              _error = null;
            });
          },
          onWebResourceError: (e) {
            debugPrint(
              'WebResourceError: ${e.description} '
              '(mainFrame: ${e.isForMainFrame})',
            );
            // Only treat main-frame errors as fatal; sub-resource errors
            // (favicon, etc.) are common and harmless.
            if (e.isForMainFrame == true) {
              setState(() {
                _error = e.description;
                _loading = false;
              });
            }
          },
          // The clip download is a navigation to an attachment URL, which
          // WKWebView cannot render ("Plug-in handled load"). Intercept it and
          // save the file natively instead.
          onNavigationRequest: (request) {
            if (_isVideoDownload(request.url)) {
              unawaited(_saveVideo(request.url));
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  /// `/api/t2v/<id>/video` is the clip download; other navigations (and the
  /// `<video>` subresource) pass through.
  bool _isVideoDownload(String url) {
    final uri = Uri.parse(url);
    return uri.path.startsWith('/api/t2v/') && uri.path.endsWith('/video');
  }

  /// Fetches the clip from the local server and saves it to the user's
  /// Downloads folder, then reveals it in Finder.
  Future<void> _saveVideo(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final client = HttpClient();
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != 200) {
        throw 'HTTP ${response.statusCode}';
      }
      final bytes = await response.fold<List<int>>(<int>[], (acc, chunk) {
        acc.addAll(chunk);
        return acc;
      });

      final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
      final dir = Directory('$home/Downloads');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final id = Uri.parse(url).pathSegments[2];
      final file = File('${dir.path}/conatus_viva_$id.mp4');
      await file.writeAsBytes(bytes, flush: true);

      await Process.run('open', <String>['-R', file.path]);
      messenger.showSnackBar(SnackBar(content: Text('已下载到 ${file.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('下载失败：$e')));
    }
  }

  Future<void> _reload() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    await controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('加载失败', style: TextStyle(fontSize: 18)),
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _reload, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: Stack(
        children: [
          WebViewWidget(controller: controller),
          if (_loading)
            const ColoredBox(
              color: Colors.white,
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
