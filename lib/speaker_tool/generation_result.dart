import 'package:flutter/material.dart';

import 'speaker_avatar.dart';

/// 生成结果展示区：视频预览（左下角叠加主讲人头像）+ 下载链接占位。
///
/// 视频预览用占位画面模拟真实视频画面，左下角的 [SpeakerAvatar]
/// 即最终会被叠加到生成视频里的主讲人。
class GenerationResult extends StatelessWidget {
  const GenerationResult({
    super.key,
    required this.downloadUrl,
    required this.theme,
  });

  /// 下载链接占位文本。
  final String downloadUrl;

  /// 主题文字，显示在视频预览画面中。
  final String theme;

  @override
  Widget build(BuildContext context) {
    if (downloadUrl.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _VideoPreview(theme: theme),
          const SizedBox(height: 12),
          _DownloadBar(url: downloadUrl),
        ],
      ),
    );
  }
}

/// 视频预览框：占位画面 + 左下角主讲人头像叠加。
class _VideoPreview extends StatelessWidget {
  const _VideoPreview({required this.theme});

  final String theme;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _PlaceholderFrame(theme: theme),
            Positioned(left: 12, bottom: 12, child: SpeakerAvatar(size: 72)),
          ],
        ),
      ),
    );
  }
}

/// 视频占位画面：渐变背景 + 主题文字居中。
class _PlaceholderFrame extends StatelessWidget {
  const _PlaceholderFrame({required this.theme});

  final String theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Text(
        theme,
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 下载链接栏：链接文本 + 下载按钮。
class _DownloadBar extends StatelessWidget {
  const _DownloadBar({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green.shade700),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              url,
              style: TextStyle(
                fontSize: 12,
                color: Colors.green.shade800,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
          TextButton(
            onPressed: () => _showPlaceholder(context),
            child: const Text('下载'),
          ),
        ],
      ),
    );
  }

  void _showPlaceholder(BuildContext context) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('下载链接为占位，暂未接入真实文件')));
  }
}
