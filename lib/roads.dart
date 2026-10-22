/// Drawing class of a road: 0 motorway … 6 service. Must match the app's road_graph.dart.
const classMotorway = 0, classTrunk = 1, classPrimary = 2, classSecondary = 3, classTertiary = 4, classMinor = 5, classService = 6;

/// Way flags. Must match the app.
const flagBridge = 1, flagTunnel = 2, flagRoundabout = 4;

/// Drivable OSM highway types: (drawing class, default km/h for Indian roads).
const roadKinds = <String, (int, int)>{
  'motorway': (classMotorway, 100), 'motorway_link': (classMotorway, 60),
  'trunk': (classTrunk, 80), 'trunk_link': (classTrunk, 50),
  'primary': (classPrimary, 60), 'primary_link': (classPrimary, 45),
  'secondary': (classSecondary, 50), 'secondary_link': (classSecondary, 40),
  'tertiary': (classTertiary, 40), 'tertiary_link': (classTertiary, 35),
  'unclassified': (classMinor, 30), 'residential': (classMinor, 25), 'road': (classMinor, 25),
  'living_street': (classMinor, 10), 'service': (classService, 15),
};

const _closed = {'no', 'private'};
const _minorService = {'driveway', 'parking_aisle', 'drive-through', 'emergency_access'};

/// What a car can do on one OSM way.
class Road {
  final int kind, speed, flags;

  /// 1 = one-way along the node order, -1 = against it, 0 = both ways.
  final int dir;
  final String name;
  const Road(this.kind, this.speed, this.flags, this.dir, this.name);

  /// The drivable road described by [t], or null when cars can't (or shouldn't) use it.
  static Road? fromTags(Map<String, String> t) {
    final hw = t['highway'];
    final kind = roadKinds[hw];
    if (kind == null || t['area'] == 'yes') return null;
    if (_closed.contains(t['access']) || _closed.contains(t['motor_vehicle']) || _closed.contains(t['motorcar'])) return null;
    if (hw == 'service' && _minorService.contains(t['service'])) return null;
    final roundabout = const {'roundabout', 'circular'}.contains(t['junction']);
    final dir = switch (t['oneway']) {
      'yes' || 'true' || '1' => 1,
      '-1' || 'reverse' => -1,
      'no' || 'false' || '0' => 0,
      _ => roundabout || hw == 'motorway' || hw == 'motorway_link' ? 1 : 0,
    };
    final flags = (_yes(t['bridge']) ? flagBridge : 0) | (_yes(t['tunnel']) ? flagTunnel : 0) | (roundabout ? flagRoundabout : 0);
    final speed = (maxspeed(t['maxspeed']) ?? kind.$2).clamp(5, 130);
    final name = (t['name:en'] ?? t['name'] ?? t['ref'] ?? '').replaceAll('\n', ' ').trim();
    return Road(kind.$1, speed, flags, dir, name);
  }

  static bool _yes(String? v) => v != null && v != 'no';

  static int? maxspeed(String? s) {
    if (s == null) return null;
    final v = int.tryParse(RegExp(r'\d+').firstMatch(s)?.group(0) ?? '');
    if (v == null) return null;
    return s.contains('mph') ? (v * 1.609).round() : v;
  }
}

/// A turn restriction at a junction node: from way → (via node) → to way.
class Restriction {
  final int fromWay, viaNode, toWay;

  /// true = "only this turn is allowed", false = "this turn is banned".
  final bool only;
  const Restriction(this.fromWay, this.viaNode, this.toWay, this.only);

  /// Reads a `type=restriction` relation that applies to cars; null for anything else (via-way restrictions are skipped).
  static Restriction? fromRelation(Map<String, String> t, List<(int, int, String)> members) {
    if (t['type'] != 'restriction') return null;
    final r = t['restriction:motorcar'] ?? t['restriction'];
    if (r == null || !(r.startsWith('no_') || r.startsWith('only_'))) return null;
    if ((t['except'] ?? '').split(';').contains('motorcar')) return null;
    int? from, via, to;
    for (final (type, id, role) in members) {
      if (role == 'from' && type == 1) from = id;
      if (role == 'to' && type == 1) to = id;
      if (role == 'via') {
        if (type != 0) return null;
        via = id;
      }
    }
    if (from == null || via == null || to == null) return null;
    return Restriction(from, via, to, r.startsWith('only_'));
  }
}
