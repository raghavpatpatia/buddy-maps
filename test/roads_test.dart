import 'package:buddy_maps/roads.dart';
import 'package:test/test.dart';

void main() {
  test('drivable roads with direction, speed and flags', () {
    final r = Road.fromTags({'highway': 'primary', 'oneway': 'yes', 'bridge': 'yes', 'maxspeed': '70', 'name': 'Ring Road'})!;
    expect((r.kind, r.speed, r.dir, r.flags, r.name), (classPrimary, 70, 1, flagBridge, 'Ring Road'));
    expect(Road.fromTags({'highway': 'residential', 'oneway': '-1'})!.dir, -1);
    expect(Road.fromTags({'highway': 'motorway'})!.dir, 1, reason: 'motorways are one-way by default');
    expect(Road.fromTags({'highway': 'tertiary', 'junction': 'roundabout'})!.flags & flagRoundabout, flagRoundabout);
    expect(Road.fromTags({'highway': 'trunk', 'maxspeed': '40 mph'})!.speed, 64);
    expect(Road.fromTags({'highway': 'primary', 'name': 'राजपथ', 'name:en': 'Kartavya Path'})!.name, 'Kartavya Path');
  });

  test('roads cars cannot use are dropped', () {
    expect(Road.fromTags({'highway': 'footway'}), isNull);
    expect(Road.fromTags({'highway': 'construction'}), isNull);
    expect(Road.fromTags({'highway': 'residential', 'access': 'private'}), isNull);
    expect(Road.fromTags({'highway': 'primary', 'motor_vehicle': 'no'}), isNull);
    expect(Road.fromTags({'highway': 'service', 'service': 'driveway'}), isNull);
    expect(Road.fromTags({'highway': 'pedestrian', 'area': 'yes'}), isNull);
  });

  test('turn restrictions for cars with a via node', () {
    const members = [(1, 10, 'from'), (0, 20, 'via'), (1, 30, 'to')];
    final no = Restriction.fromRelation({'type': 'restriction', 'restriction': 'no_left_turn'}, members)!;
    expect((no.fromWay, no.viaNode, no.toWay, no.only), (10, 20, 30, false));
    expect(Restriction.fromRelation({'type': 'restriction', 'restriction': 'only_straight_on'}, members)!.only, isTrue);
    expect(Restriction.fromRelation({'type': 'restriction', 'restriction': 'no_u_turn', 'except': 'bicycle;motorcar'}, members), isNull);
    expect(Restriction.fromRelation({'type': 'restriction', 'restriction': 'no_left_turn'}, const [(1, 10, 'from'), (1, 20, 'via'), (1, 30, 'to')]), isNull,
        reason: 'via-way restrictions are not supported');
    expect(Restriction.fromRelation({'type': 'route'}, members), isNull);
  });
}
