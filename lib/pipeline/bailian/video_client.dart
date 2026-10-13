import 'package:http/http.dart' as http;

import 'dashscope_video.dart';
import 'i2v.dart';
import 'wan30_video.dart';

/// Builds the async video client for [model]: the `wan3*` family routes to the
/// wan3.0 all-in-one client, everything else to the wan2.6 i2v client. This is
/// the single seam that turns a CLI/config model name into a concrete client,
/// so the pipeline never has to branch on model version itself.
VideoGenClient buildVideoClient({
  required String model,
  required String apiKey,
  http.Client? client,
  String? host,
  required String resolution,
  required bool watermark,
  required int seed,
}) {
  if (model.startsWith('wan3')) {
    return Wan30VideoClient(
      apiKey: apiKey,
      client: client,
      host: host,
      model: model,
      resolution: resolution,
      watermark: watermark,
      seed: seed,
    );
  }
  return I2vClient(
    apiKey: apiKey,
    client: client,
    host: host,
    model: model,
    resolution: resolution,
    watermark: watermark,
    seed: seed,
  );
}
