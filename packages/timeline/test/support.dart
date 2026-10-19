import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:cryptography/dart.dart' show DartEd25519;
import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Loads the time zone database and returns New York; shared by the tests.
tz.Location loadNewYork() {
  tzdata.initializeTimeZones();
  return tz.getLocation('America/New_York');
}

/// A local time in [zone].
tz.TZDateTime local(
  String zone,
  int y,
  int mo,
  int d,
  int h, [
  int mi = 0,
  int s = 0,
]) => tz.TZDateTime(tz.getLocation(zone), y, mo, d, h, mi, s);

/// Anchors with only the appointment known.
Anchors appointment(tz.TZDateTime a) =>
    (appointment: a, arrival: null, discharge: null);

const protocols = '../../fixtures/protocols';

/// The fixture protocols, and the zones they and the tests use.
const umms = 'colo-golytely-split-am-umms';
const bmc = 'colo-golytely-split-bmc';
const karmanos = 'colo-miralax-split-karmanos';
const uw = 'cardiac-cath-uw';
const msk = 'surgery-anesthesia-msk';
const ccf = 'colo-sutab-low-volume-ccf';

const ny = 'America/New_York';
const la = 'America/Los_Angeles';
const detroit = 'America/Detroit';

/// A fresh copy each call, so a test can change it.
Map<String, Object?> readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

Map<String, Object?> fixture(String path) => readJson('$protocols/$path');

List<Directory> protocolDirs() =>
    Directory(protocols).listSync().whereType<Directory>().toList();

/// The label the signed message starts with (docs/spec.md, Changeability).
final label = ascii.encode('prep-timeline/manifest/v1');

typedef Files = ({List<int> manifest, List<List<int>> modules});

/// A protocol directory's manifest bytes and module bytes, by file name.
Files filesIn(String dir) {
  final paths = [
    for (final f in Directory(dir).listSync().whereType<File>()) f.path,
  ]..sort();
  return (
    manifest: File('$dir/protocol.json').readAsBytesSync(),
    modules: [
      for (final p in paths)
        if (!p.endsWith('protocol.json')) File(p).readAsBytesSync(),
    ],
  );
}

String hexSha(List<int> bytes) => sha256.convert(bytes).toString();

/// The tests' signing key, from a fixed seed; another [seed] gives another
/// key.
Future<SimpleKeyPair> testKey([int seed = 1]) =>
    DartEd25519().newKeyPairFromSeed(List.filled(32, seed));

/// The 64-byte signature protocol.sig encodes: over the label, then the
/// SHA-256 of the manifest's bytes.
Future<List<int>> signatureOf(List<int> manifest, SimpleKeyPair by) async =>
    (await DartEd25519().sign([
      ...label,
      ...sha256.convert(manifest).bytes,
    ], keyPair: by)).bytes;

List<int> sigText(List<int> signature) =>
    ascii.encode(base64.encode(signature));

/// Fixture [protocol] as the app gets it: signed with [testKey] and checked
/// by verifyBundle. [manifest] and [modules], by file name such as 'base',
/// change the JSON first; a changed module's new SHA-256 replaces its old one
/// in the manifest, so only a test that means to break the bundle does.
Future<Bundle> signedBundle(
  String protocol, {
  void Function(Map<String, Object?> json)? manifest,
  Map<String, void Function(Map<String, Object?> json)> modules = const {},
}) async {
  final f = editedFiles(protocol, manifest: manifest, modules: modules);
  final key = await testKey();
  return verifyBundle(
    manifest: f.manifest,
    signature: sigText(await signatureOf(f.manifest, key)),
    modules: f.modules,
    publicKey: (await key.extractPublicKey()).bytes,
  );
}

/// Fixture [protocol]'s files, unsigned, changed as [signedBundle] changes
/// them.
Files editedFiles(
  String protocol, {
  void Function(Map<String, Object?> json)? manifest,
  Map<String, void Function(Map<String, Object?> json)> modules = const {},
}) {
  final dir = '$protocols/$protocol';
  var manifestText = File('$dir/protocol.json').readAsStringSync();
  final moduleFiles = <List<int>>[];
  final edited = <String>{};
  for (final f in Directory(dir).listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), '');
    if (name == 'protocol') continue;
    var bytes = f.readAsBytesSync();
    if (modules[name] case final edit?) {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      edit(json);
      final changed = utf8.encode(jsonEncode(json));
      expect(hexSha(bytes).allMatches(manifestText), hasLength(1));
      manifestText = manifestText.replaceFirst(hexSha(bytes), hexSha(changed));
      bytes = changed;
      edited.add(name);
    }
    moduleFiles.add(bytes);
  }
  // A misspelt file name would otherwise leave the fixture unchanged.
  expect(edited, modules.keys.toSet());
  if (manifest != null) {
    final json = jsonDecode(manifestText) as Map<String, Object?>;
    manifest(json);
    manifestText = jsonEncode(json);
  }
  return (manifest: utf8.encode(manifestText), modules: moduleFiles);
}

/// Fixture module [path] and its step [id], as JSON.
({Map<String, Object?> module, Map<String, Object?> step}) fixtureJson(
  String path,
  String id,
) {
  final module = jsonDecode(
    File('../../fixtures/protocols/$path').readAsStringSync(),
  ) as Map<String, Object?>;
  final step = (module['steps']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .singleWhere((s) => s['id'] == id);
  return (module: module, step: step);
}

/// One step's JSON as a timed step; [day] turns a day number into days.
TimedStep stepFrom(Map<String, Object?> s, int Function(Object? d) day) => (
  id: s['id']! as String,
  anchor: Anchor.values.byName(s['anchor']! as String),
  timing: parseTiming(s['timing']! as Map<String, Object?>, day),
  remind: parseRemind(s['remind']! as Map<String, Object?>, day),
  allowNight: s['allowNight']! as bool,
  pastDue: PastDue.values.byName(s['pastDue']! as String),
);

/// A timed step from a fixture module, parsed the way the app will parse it,
/// with [chosen] parameter values.
TimedStep fixtureStep(
  String path,
  String id, [
  Map<String, int> chosen = const {},
]) {
  final (:module, :step) = fixtureJson(path, id);
  final params =
      (module['parameters'] ?? <String, Object?>{}) as Map<String, Object?>;
  return stepFrom(step, (d) => resolveDay(d, params, chosen));
}

bool inRange(({int hour, int minute}) clock, QuietHours range) {
  final c = clock.hour * 60 + clock.minute;
  final from = range.from.hour * 60 + range.from.minute;
  final to = range.to.hour * 60 + range.to.minute;
  return from <= to ? from <= c && c < to : c >= from || c < to;
}

typedef SampledStep = ({
  String name,
  TimedStep step,
  tz.Location zone,
  QuietHours bookable,
});

/// Every timed step in fixtures/protocols, each parameter at its lowest and
/// highest value, with its protocol's zone and bookable hours.
Iterable<SampledStep> everyFixtureStep() sync* {
  Map<String, Object?> read(String path) =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
  final protocols = Directory('../../fixtures/protocols').listSync();
  for (final dir in protocols.whereType<Directory>()) {
    final manifest = read('${dir.path}/protocol.json');
    final hours = manifest['bookableHours']! as Map<String, Object?>;
    final zone = tz.getLocation(manifest['timezone']! as String);
    final bookable = (
      from: parseClockTime(hours['from']! as String),
      to: parseClockTime(hours['to']! as String),
    );
    for (final file in dir.listSync().whereType<File>()) {
      if (file.path.endsWith('protocol.json')) continue;
      final module = read(file.path);
      final params =
          (module['parameters'] ?? <String, Object?>{}) as Map<String, Object?>;
      for (final end in const ['min', 'max']) {
        final picked = params.map(
          (name, range) =>
              MapEntry(name, (range! as Map<String, Object?>)[end]! as int),
        );
        int day(Object? d) => resolveDay(d, params, picked);
        final steps = module['steps']! as List<Object?>;
        for (final s in steps.cast<Map<String, Object?>>()) {
          if (s.containsKey('timing')) {
            yield (
              name: '${module['moduleId']}/${s['id']}',
              step: stepFrom(s, day),
              zone: zone,
              bookable: bookable,
            );
          }
        }
      }
    }
  }
}

/// The publish check's dates: an ordinary one, then each 2026-2027 clock
/// change of the fixtures' US zones.
const publishDates = [
  (2026, 11, 18),
  (2026, 3, 8),
  (2026, 11, 1),
  (2027, 3, 14),
  (2027, 11, 7),
];

/// The publish check's samples (docs/spec.md, Conflict check at publish):
/// every 15 minutes inside bookable hours, with arrival at the appointment,
/// or across the whole day for discharge; on an ordinary date and on each
/// 2026-2027 clock-change date of the fixtures' US zones.
void forEverySample(
  void Function(SampledStep f, Anchors anchors, tz.TZDateTime sample) check,
) {
  for (final f in everyFixtureStep()) {
    for (final (y, m, d) in publishDates) {
      for (var minute = 0; minute < 24 * 60; minute += 15) {
        final clock = (hour: minute ~/ 60, minute: minute % 60);
        final discharge = f.step.anchor == Anchor.discharge;
        if (!discharge && !inRange(clock, f.bookable)) continue;
        final t = localTime(f.zone, y, m, d, clock.hour, clock.minute);
        final Anchors anchors = switch (f.step.anchor) {
          Anchor.appointment => (
            appointment: t,
            arrival: null,
            discharge: null,
          ),
          Anchor.arrival => (appointment: t, arrival: t, discharge: null),
          Anchor.discharge => (
            appointment: localTime(f.zone, y, m, d, 0, 0),
            arrival: null,
            discharge: t,
          ),
        };
        check(f, anchors, t);
      }
    }
  }
}

/// Counts failures across a sample space and keeps the first, so a property
/// reports one counterexample instead of thousands.
final class Failures {
  var count = 0;
  String? first;

  void check(bool ok, String Function() describe) {
    if (ok) return;
    count++;
    first ??= describe();
  }

  void expectNone() => expect(count, 0, reason: 'first counterexample: $first');
}

/// The order L of the Ed25519 base point.
final ed25519Order =
    BigInt.two.pow(252) +
    BigInt.parse('27742317777372353535851937790883648493');

/// [signature] with S replaced by S + L: the same scalar mod L, so only a
/// verifier that checks S < L (RFC 8032, section 5.1.7) rejects it.
List<int> nonCanonicalS(List<int> signature) {
  final s = signature
      .sublist(32)
      .reversed
      .fold(BigInt.zero, (n, b) => (n << 8) | BigInt.from(b));
  final big = s + ed25519Order;
  expect(big.bitLength, lessThanOrEqualTo(256));
  return [
    ...signature.sublist(0, 32),
    for (var i = 0; i < 32; i++) ((big >> (8 * i)) & BigInt.from(0xff)).toInt(),
  ];
}
