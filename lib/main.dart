import 'package:flutter/material.dart';

import 'speaker_tool/speaker_env.dart';
import 'speaker_tool/speaker_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SpeakerEnv.init();
  runApp(const SpeakerApp());
}

class SpeakerApp extends StatelessWidget {
  const SpeakerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '方言配音主讲人',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const SpeakerPage(),
    );
  }
}
