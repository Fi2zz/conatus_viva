import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'server/start.dart';
import 'server/web_build_assets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final staticDir = await materializeWebBuild(rootBundle);
  final avatarImage = await materializeAssetFile(
    rootBundle,
    key: 'assets/images/speaker_avatar.jpg',
    suffix: '.jpg',
  );
  final url = await startPipelineServer(
    staticDir: staticDir.path,
    avatarImage: avatarImage,
  );
  runApp(SpeakerApp(serverUrl: url));
}

class SpeakerApp extends StatelessWidget {
  const SpeakerApp({super.key, required this.serverUrl});

  final String serverUrl;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '方言配音主讲人',
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
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
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
    return Stack(
      children: [
        WebViewWidget(controller: controller),
        if (_loading)
          const ColoredBox(
            color: Colors.white,
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}
