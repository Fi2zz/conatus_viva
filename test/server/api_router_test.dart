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

    test('settings routes are GET/PUT only', () {
      expect(apiRouteFor('GET', '/api/settings'), ApiRoute.settings);
      expect(apiRouteFor('PUT', '/api/settings'), ApiRoute.settings);
      expect(apiRouteFor('POST', '/api/settings'), ApiRoute.unknown);
      expect(apiRouteFor('GET', '/api/settings/x'), ApiRoute.unknown);
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

    test('image + models routes, file wins over bare id', () {
      expect(apiRouteFor('GET', '/api/models'), ApiRoute.getModels);
      expect(apiRouteFor('POST', '/api/images'), ApiRoute.createImage);
      expect(apiRouteFor('GET', '/api/images/img-1/2'), ApiRoute.getImageFile);
      expect(apiRouteFor('GET', '/api/images/img-1'), ApiRoute.getImage);
      expect(apiRouteFor('POST', '/api/images/img-1/2'), ApiRoute.unknown);
      expect(apiRouteFor('GET', '/api/models/x'), ApiRoute.unknown);
    });

    test('video routes, file wins over bare id', () {
      expect(apiRouteFor('POST', '/api/videos'), ApiRoute.createVideo);
      expect(
        apiRouteFor('GET', '/api/videos/vid-1/video'),
        ApiRoute.getVideoFile,
      );
      expect(apiRouteFor('GET', '/api/videos/vid-1'), ApiRoute.getVideo);
      expect(apiRouteFor('POST', '/api/videos/vid-1'), ApiRoute.unknown);
    });

    test('short-drama plan route, GET only with an id', () {
      expect(
        apiRouteFor('GET', '/api/short-drama/plans/ep07'),
        ApiRoute.getShortDramaPlan,
      );
      expect(
        apiRouteFor('GET', '/api/short-drama/plans/ep-07_abc'),
        ApiRoute.getShortDramaPlan,
      );
      expect(
        apiRouteFor('POST', '/api/short-drama/plans/ep07'),
        ApiRoute.unknown,
      );
      expect(apiRouteFor('GET', '/api/short-drama/plans'), ApiRoute.unknown);
      expect(
        apiRouteFor('GET', '/api/short-drama/other'),
        ApiRoute.unknown,
      );
    });

    test('drama routes all methods go to the drama controller', () {
      expect(apiRouteFor('GET', '/api/drama/series'), ApiRoute.drama);
      expect(apiRouteFor('POST', '/api/drama/series'), ApiRoute.drama);
      expect(apiRouteFor('PUT', '/api/drama/series/jietiao'), ApiRoute.drama);
      expect(
        apiRouteFor('POST', '/api/drama/series/jietiao/episodes/ep07/storyboard:draft'),
        ApiRoute.drama,
      );
      expect(apiRouteFor('GET', '/api/drama'), ApiRoute.unknown);
      expect(apiRouteFor('GET', '/api/dramaX/series'), ApiRoute.unknown);
    });
  });
}
