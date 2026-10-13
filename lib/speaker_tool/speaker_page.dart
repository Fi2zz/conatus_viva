import 'package:flutter/material.dart';

import 'generation_result.dart';
import 'speaker_form.dart';

/// 主讲人工具主页面。
///
/// 参数表单配置时长、方言、主题文字；生成后展示视频预览
/// （左下角叠加主讲人头像）和下载链接占位。
class SpeakerPage extends StatefulWidget {
  const SpeakerPage({super.key});

  @override
  State<SpeakerPage> createState() => _SpeakerPageState();
}

class _SpeakerPageState extends State<SpeakerPage> {
  int _duration = 30;
  String _dialect = 'mandarin';
  String _theme = '';
  bool _generating = false;
  String _downloadUrl = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('方言配音主讲人')),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            SpeakerForm(
              duration: _duration,
              dialectLabel: _dialect,
              theme: _theme,
              onDurationChanged: (v) => setState(() => _duration = v),
              onDialectChanged: (v) => setState(() => _dialect = v),
              onThemeChanged: (v) => setState(() => _theme = v),
              onGenerate: _handleGenerate,
              generating: _generating,
            ),
            GenerationResult(downloadUrl: _downloadUrl, theme: _theme),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Future<void> _handleGenerate() async {
    if (_theme.trim().isEmpty) {
      _showError('请先输入主题文字');
      return;
    }
    setState(() {
      _generating = true;
      _downloadUrl = '';
    });
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() {
      _generating = false;
      _downloadUrl =
          'https://example.com/downloads/speaker_${DateTime.now().millisecondsSinceEpoch}.mp4';
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
