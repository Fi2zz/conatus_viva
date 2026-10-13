import 'package:flutter/material.dart';

/// 卡通主讲人头像，用于叠加到视频画面的左下角。
///
/// 本身不包含定位逻辑，需由父级 [Stack] 中的 [Positioned] 决定位置。
/// 可选传入 [speech] 显示气泡文字。
class SpeakerAvatar extends StatelessWidget {
  const SpeakerAvatar({super.key, this.speech, this.size = 96});

  /// 头像旁气泡中显示的文字；为 null 时不显示气泡。
  final String? speech;

  /// 头像直径，默认 96。
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SpeechBubble(text: speech),
        const SizedBox(width: 8),
        _AvatarImage(size: size),
      ],
    );
  }
}

class _AvatarImage extends StatelessWidget {
  const _AvatarImage({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset('assets/images/speaker_avatar.jpg', fit: BoxFit.cover),
    );
  }
}

class _SpeechBubble extends StatelessWidget {
  const _SpeechBubble({this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    if (text == null || text!.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Text(
        text!,
        style: const TextStyle(fontSize: 13, color: Colors.black87),
      ),
    );
  }
}
