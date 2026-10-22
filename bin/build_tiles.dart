import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buddy_maps/buffers.dart';
import 'package:buddy_maps/pbf.dart';
import 'package:buddy_maps/roads.dart';
import 'package:buddy_maps/tile_format.dart';

/// Usage: dart run bin/build_tiles.dart <input.osm.pbf> <out dir> <country name>
///
/// Reads every drivable road and car turn restriction, cuts them into 1° tiles and writes
/// `<lat>_<lon>.brt.gz` files plus `manifest.json` describing them.
Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: build_tiles <input.osm.pbf> <out dir> <country>');
    exit(64);
  }
  final sw = Stopwatch()..start();
  void log(String s) => print('[${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s] $s');
  final reader = PbfReader(args[0]);
  final out = Directory(args[1])..createSync(recursive: true);

  // ---- Pass 1: roads, restrictions, and which blocks hold nodes ----
  final wayIds = I64(), refs = I64(), refStart = I32()..add(0), names = <String>[], nameIdx = <String, int>{};
  final kind = U8(), speed = U8(), flags = U8(), dir = U8(), wayName = I32();
  final restrictions = <Restriction>[];
  final nodeBlocks = <int>{};
  await reader.read((offset, b) {
    if (b.hasNodes) nodeBlocks.add(offset);
    if (b.hasWays) {
      b.ways((id, tags, nodes) {
        final r = Road.fromTags(tags);
        if (r == null || nodes.length < 2) return;
        wayIds.add(id);
        for (final n in nodes) {
          refs.add(n);
        }
        refStart.add(refs.length);
        kind.add(r.kind);
        speed.add(r.speed);
        flags.add(r.flags);
        dir.add(r.dir & 0xFF);
        wayName.add(r.name.isEmpty ? -1 : nameIdx.putIfAbsent(r.name, () => (names..add(r.name)).length - 1));
      });
    }
    if (b.hasRelations) {
      b.relations((id, tags, members) {
        final r = Restriction.fromRelation(tags, members);
        if (r != null) restrictions.add(r);
      });
    }
  });
  final wv = wayIds.view();
  for (var i = 1; i < wv.length; i++) {
    if (wv[i] <= wv[i - 1]) throw StateError('Input must be sorted by id (Geofabrik extracts are); run `osmium sort` first.');
  }
  log('pass 1: ${wayIds.length} roads, ${refs.length} refs, ${restrictions.length} turn restrictions');

  // ---- Node ids we need, sorted and unique ----
  final ids = refs.view().sublist(0)..sort();
  var u = 0;
  for (var i = 0; i < ids.length; i++) {
    if (i == 0 || ids[i] != ids[i - 1]) ids[u++] = ids[i];
  }
  final nodeIds = Int64List.sublistView(ids, 0, u);
  final lat = Int32List(u), lon = Int32List(u), has = Uint8List(u);
  log('${nodeIds.length} road nodes');

  // ---- Pass 2: coordinates of those nodes ----
  await reader.read(wantBlock: nodeBlocks.contains, (_, b) {
    b.nodes((id, la, lo) {
      final i = lowerBound(nodeIds, id);
      if (i < u && nodeIds[i] == id) {
        lat[i] = la;
        lon[i] = lo;
        has[i] = 1;
      }
    });
  });
  log('pass 2: coordinates read');

  // ---- Refs as node indexes (-1 when the extract lacks the node) ----
  final r = refs.view();
  final refIdx = Int32List(r.length);
  for (var i = 0; i < r.length; i++) {
    final k = lowerBound(nodeIds, r[i]);
    refIdx[i] = k < u && nodeIds[k] == r[i] && has[k] == 1 ? k : -1;
  }

  // ---- Tiles: every way goes to each 1° tile one of its nodes lies in ----
  int tileOf(int n) => (_floorDeg(lat[n]) + 500) * 1000 + _floorDeg(lon[n]) + 500;
  final tiles = <int, I32>{};
  final rs = refStart.view(), wid = wayIds.view();
  for (var w = 0; w < wid.length; w++) {
    final seen = <int>{};
    for (var i = rs[w]; i < rs[w + 1]; i++) {
      if (refIdx[i] >= 0 && seen.add(tileOf(refIdx[i]))) (tiles[tileOf(refIdx[i])] ??= I32()).add(w);
    }
  }
  final tileRestr = <int, List<Restriction>>{};
  for (final x in restrictions) {
    final k = lowerBound(nodeIds, x.viaNode);
    if (k < u && nodeIds[k] == x.viaNode && has[k] == 1) (tileRestr[tileOf(k)] ??= []).add(x);
  }
  log('${tiles.length} tiles');

  // ---- Write ----
  final manifestTiles = <String, dynamic>{};
  final kv = kind.view(), sv = speed.view(), fv = flags.view(), dv = dir.view(), nv = wayName.view();
  final sortedKeys = tiles.keys.toList()..sort();
  for (final key in sortedKeys) {
    final ways = tiles[key]!.view(); // ascending global way indexes
    final usedSet = <int>{};
    var refCount = 0;
    for (final w in ways) {
      for (var i = rs[w]; i < rs[w + 1]; i++) {
        if (refIdx[i] >= 0) usedSet.add(refIdx[i]);
      }
      refCount += rs[w + 1] - rs[w];
    }
    final used = Int32List.fromList(usedSet.toList()..sort());
    final tRefStart = Int32List(ways.length + 1), tRefs = Int32List(refCount), tName = Int32List(ways.length);
    final tNames = <String>[], tNameIdx = <int, int>{};
    for (var j = 0; j < ways.length; j++) {
      final w = ways[j];
      var at = tRefStart[j];
      for (var i = rs[w]; i < rs[w + 1]; i++) {
        tRefs[at++] = refIdx[i] < 0 ? -1 : lowerBound32(used, refIdx[i]);
      }
      tRefStart[j + 1] = at;
      tName[j] = nv[w] < 0 ? -1 : tNameIdx.putIfAbsent(nv[w], () => (tNames..add(names[nv[w]])).length - 1);
    }
    // Restrictions whose ways are both here.
    final rf = <int>[], rv = <int>[], rt = <int>[], ro = <int>[];
    for (final x in tileRestr[key] ?? const <Restriction>[]) {
      final fw = lowerBound(wid, x.fromWay), tw = lowerBound(wid, x.toWay);
      if (fw >= wid.length || wid[fw] != x.fromWay || tw >= wid.length || wid[tw] != x.toWay) continue;
      final fj = lowerBound32(ways, fw), tj = lowerBound32(ways, tw);
      if (fj >= ways.length || ways[fj] != fw || tj >= ways.length || ways[tj] != tw) continue;
      final vn = lowerBound(nodeIds, x.viaNode);
      rf.add(fj);
      rv.add(lowerBound32(used, vn));
      rt.add(tj);
      ro.add(x.only ? 1 : 0);
    }
    final t = TileData(
      nodeIds: Int64List.fromList([for (final n in used) nodeIds[n]]),
      lat: Int32List.fromList([for (final n in used) lat[n]]),
      lon: Int32List.fromList([for (final n in used) lon[n]]),
      wayIds: Int64List.fromList([for (final w in ways) wid[w]]),
      refStart: tRefStart,
      refs: tRefs,
      kind: Uint8List.fromList([for (final w in ways) kv[w]]),
      speed: Uint8List.fromList([for (final w in ways) sv[w]]),
      flags: Uint8List.fromList([for (final w in ways) fv[w]]),
      dir: Int8List.fromList([for (final w in ways) dv[w].toSigned(8)]),
      name: tName,
      restrFrom: Int32List.fromList(rf),
      restrVia: Int32List.fromList(rv),
      restrTo: Int32List.fromList(rt),
      restrOnly: Uint8List.fromList(ro),
      names: tNames,
    );
    final raw = t.toBytes();
    final gz = GZipCodec(level: 9).encode(raw);
    final name = '${key ~/ 1000 - 500}_${key % 1000 - 500}';
    File('${out.path}/$name.brt.gz').writeAsBytesSync(gz);
    manifestTiles[name] = {'bytes': gz.length, 'raw': raw.length, 'nodes': used.length, 'ways': ways.length, 'restrictions': ro.length};
  }
  final manifest = {
    'format': tileFormat,
    'country': args[2],
    'tileDeg': 1,
    'built': DateTime.now().toUtc().toIso8601String(),
    'data': reader.timestamp == null ? null : DateTime.fromMillisecondsSinceEpoch(reader.timestamp! * 1000, isUtc: true).toIso8601String(),
    'license': 'Map data © OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright)',
    'tiles': manifestTiles,
  };
  File('${out.path}/manifest.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(manifest));
  final total = manifestTiles.values.fold<int>(0, (a, t) => a + (t['bytes'] as int));
  log('wrote ${manifestTiles.length} tiles, ${(total / 1e6).toStringAsFixed(1)} MB');
}

int _floorDeg(int e7) => (e7 / 1e7).floor();
