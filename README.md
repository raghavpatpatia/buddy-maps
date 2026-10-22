# buddy-maps

Free "map server" for the [Buddy](https://github.com/raghavpatpatia/Buddy) app's offline navigation.

Every Monday a GitHub Action downloads the latest India extract from [Geofabrik](https://download.geofabrik.de/asia/india.html),
keeps only drivable roads and car turn restrictions, cuts them into 1° tiles and publishes them to the
[`india` release](../../releases/tag/india). Phones download only the tiles under the area the user picks.

No servers run: building is GitHub Actions, hosting is GitHub Releases (both free for public repos).

## What the tiles contain

`bin/build_tiles.dart` reads the `.osm.pbf` directly (pure Dart, `lib/pbf.dart`) and decides what a car can do
(`lib/roads.dart`), so the app never has to parse OSM tags:

- **Roads:** motorway … residential and useful service roads. Private, closed and non-car ways are dropped.
- **Per road:** class, speed (from `maxspeed`, else a default per road type), direction (one-way rules,
  motorways and roundabouts), flags (bridge/flyover, tunnel, roundabout) and name (English name when tagged).
- **Turn restrictions:** `no_*` and `only_*` relations for cars, with a via node.

A way that crosses tile edges is stored whole in every tile it touches, and nodes keep their OSM ids,
so the app joins tiles without gaps. The binary layout is documented in `lib/tile_format.dart` (`format` in the
manifest; bump it when the layout changes).

`manifest.json` lists every tile with its download size, node / way / restriction counts, the build time and the
OSM data date. The app uses it to show the download size before you download and to offer updates.

## Run it locally

```sh
dart pub get
dart test
curl -LO https://download.geofabrik.de/asia/india/northern-zone-latest.osm.pbf
dart run bin/build_tiles.dart northern-zone-latest.osm.pbf out India
```

The northern zone (224 MB) builds in about 45 s using under 1 GB of memory. All of India needs a few GB, which the
standard GitHub runner has.

## License

Code: MIT. Map data © OpenStreetMap contributors, available under the
[Open Database License 1.0](https://www.openstreetmap.org/copyright); the tiles are a derived database under the same license.
