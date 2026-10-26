import 'package:flutter_wanxiang/pipeline/drama/plan_view.dart';
import 'package:flutter_wanxiang/pipeline/render_plan.dart';
import 'package:test/test.dart';

void main() {
  test('reads route, i2v seconds and duration', () {
    final view = DramaPlanView(<String, Object?>{
      'shots': <Object?>[
        <String, Object?>{
          'shot_id': 's01',
          'route': 'i2v',
          'i2v_seconds': 3,
          'duration_s': 3.2,
        },
        <String, Object?>{
          'shot_id': 's02',
          'route': 'kenburns',
          'i2v_seconds': 0,
          'duration_s': 2,
        },
      ],
    });
    expect(view.routeFor('s01'), ShotRoute.i2v);
    expect(view.i2vSecondsFor('s01'), 3);
    expect(view.durationFor('s01'), closeTo(3.2, 0.001));
    expect(view.routeFor('s02'), ShotRoute.kenburns);
  });

  test('unknown shots fall back to a zero-cost micro clip', () {
    final view = DramaPlanView(<String, Object?>{});
    expect(view.routeFor('s99'), ShotRoute.micro);
    expect(view.i2vSecondsFor('s99'), 0);
    expect(view.durationFor('s99'), 2.0);
  });

  test('unknown route names fall back to micro', () {
    final view = DramaPlanView(<String, Object?>{
      'shots': <Object?>[
        <String, Object?>{'shot_id': 's01', 'route': 'unknown', 'duration_s': 2},
      ],
    });
    expect(view.routeFor('s01'), ShotRoute.micro);
  });
}
