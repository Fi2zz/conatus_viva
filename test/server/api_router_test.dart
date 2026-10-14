import 'package:flutter_wanxiang/server/api_router.dart';
import 'package:test/test.dart';

void main() {
  group('apiRouteFor', () {
    test('t2v routes, video wins over bare id', () {
      expect(apiRouteFor('GET', '/api/dialects'), ApiRoute.dialects);
      expect(apiRouteFor('GET', '/api/edit-models'), ApiRoute.getEditModels);
      expect(apiRouteFor('POST', '/api/t2v'), ApiRoute.createT2v);
      expect(apiRouteFor('GET', '/api/t2v/run-1/video'), ApiRoute.getT2vVideo);
      expect(apiRouteFor('GET', '/api/t2v/run-1'), ApiRoute.getT2v);
    });

    test('non-matching methods and paths are unknown', () {
      expect(apiRouteFor('POST', '/api/t2v/run-1/video'), ApiRoute.unknown);
      expect(apiRouteFor('GET', '/api/t2v'), ApiRoute.unknown);
      expect(apiRouteFor('POST', '/api/dialects'), ApiRoute.unknown);
      expect(apiRouteFor('POST', '/api/edit-models'), ApiRoute.unknown);
      expect(apiRouteFor('GET', '/api/runs'), ApiRoute.unknown);
      expect(apiRouteFor('GET', '/api/runsx'), ApiRoute.unknown);
      expect(apiRouteFor('GET', '/api/nope'), ApiRoute.unknown);
      expect(apiRouteFor('GET', '/favicon.ico'), ApiRoute.unknown);
    });
  });
}
