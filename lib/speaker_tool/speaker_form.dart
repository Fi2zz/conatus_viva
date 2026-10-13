import 'package:flutter/material.dart';

import 'dialect_options.dart';

/// 主讲人参数表单：时长、方言类型、主题文字。
///
/// 参数变化通过 [onChanged] 回调实时上报；
/// 点击「生成」按钮触发 [onGenerate]。
class SpeakerForm extends StatelessWidget {
  const SpeakerForm({
    super.key,
    required this.duration,
    required this.dialectLabel,
    required this.theme,
    required this.onDurationChanged,
    required this.onDialectChanged,
    required this.onThemeChanged,
    required this.onGenerate,
    required this.generating,
  });

  final int duration;
  final String dialectLabel;
  final String theme;
  final ValueChanged<int> onDurationChanged;
  final ValueChanged<String> onDialectChanged;
  final ValueChanged<String> onThemeChanged;
  final VoidCallback onGenerate;
  final bool generating;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DurationField(value: duration, onChanged: onDurationChanged),
          const SizedBox(height: 20),
          _DialectField(value: dialectLabel, onChanged: onDialectChanged),
          const SizedBox(height: 20),
          _ThemeField(value: theme, onChanged: onThemeChanged),
          const SizedBox(height: 32),
          _GenerateButton(
            onPressed: generating ? null : onGenerate,
            generating: generating,
          ),
        ],
      ),
    );
  }
}

class _DurationField extends StatelessWidget {
  const _DurationField({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('时长（秒）', style: Theme.of(context).textTheme.titleSmall),
        Slider(
          value: value.toDouble(),
          min: 5,
          max: 120,
          divisions: 23,
          label: '$value 秒',
          onChanged: (v) => onChanged(v.round()),
        ),
      ],
    );
  }
}

class _DialectField extends StatelessWidget {
  const _DialectField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      decoration: const InputDecoration(
        labelText: '方言类型',
        border: OutlineInputBorder(),
      ),
      initialValue: value,
      items: kDialectOptions
          .map(
            (d) => DropdownMenuItem(value: d.label, child: Text(d.displayName)),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _ThemeField extends StatelessWidget {
  const _ThemeField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: TextEditingController(text: value),
      textDirection: TextDirection.ltr,
      decoration: const InputDecoration(
        labelText: '主题文字',
        hintText: '例如：今天给大家讲讲河南的美食',
        border: OutlineInputBorder(),
      ),
      maxLines: 3,
      onChanged: onChanged,
    );
  }
}

class _GenerateButton extends StatelessWidget {
  const _GenerateButton({required this.onPressed, required this.generating});

  final VoidCallback? onPressed;
  final bool generating;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: generating
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.mic),
      label: Text(generating ? '生成中…' : '生成配音视频'),
    );
  }
}
