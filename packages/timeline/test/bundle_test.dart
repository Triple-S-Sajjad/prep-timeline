import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:test/test.dart';
import 'package:timeline/timeline.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support.dart';

const umms = 'colo-golytely-split-am-umms';
const uw = 'cardiac-cath-uw';

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

Files files(String protocol) => filesIn('$protocols/$protocol');

String moduleIdOf(List<int> module) =>
    (jsonDecode(utf8.decode(module)) as Map<String, Object?>)['moduleId']!
        as String;

String hexSha(List<int> bytes) => sha256.convert(bytes).toString();

/// [bytes] as UTF-8 with [from], which must occur exactly once, replaced.
List<int> edit(List<int> bytes, String from, String to) {
  final text = utf8.decode(bytes);
  expect(from.allMatches(text), hasLength(1), reason: from);
  return utf8.encode(text.replaceFirst(from, to));
}

List<int> sigText(List<int> signature) =>
    ascii.encode(base64.encode(signature));

/// Whether [run] refused the bundle and why; null when it was accepted. Any
/// other exception fails the test.
Future<BundleRefusal?> refusal(Future<Object?> Function() run) async {
  try {
    await run();
    return null;
  } on BundleRefused catch (e) {
    return e.reason;
  }
}

Matcher refused(BundleRefusal reason, [String? moduleId]) => throwsA(
  isA<BundleRefused>()
      .having((e) => e.reason, 'reason', reason)
      .having((e) => e.moduleId, 'moduleId', moduleId),
);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  final ed25519 = DartEd25519();
  late SimpleKeyPair key;
  late SimpleKeyPair otherKey;
  late List<int> publicKey;

  setUpAll(() async {
    key = await ed25519.newKeyPairFromSeed(List.filled(32, 1));
    otherKey = await ed25519.newKeyPairFromSeed(List.filled(32, 2));
    publicKey = (await key.extractPublicKey()).bytes;
  });

  Future<List<int>> rawSign(List<int> message, [SimpleKeyPair? by]) async =>
      (await ed25519.sign(message, keyPair: by ?? key)).bytes;

  /// The 64-byte signature protocol.sig encodes: over the label, then the
  /// SHA-256 of the manifest's bytes.
  Future<List<int>> signatureOf(List<int> manifest, [SimpleKeyPair? by]) =>
      rawSign([...label, ...sha256.convert(manifest).bytes], by);

  /// protocol.sig's contents for [manifest].
  Future<List<int>> sigFor(List<int> manifest, [SimpleKeyPair? by]) async =>
      sigText(await signatureOf(manifest, by));

  Future<Bundle> verify(
    List<int> manifest,
    List<int>? signature,
    List<List<int>> modules, {
    List<int>? publicKeyBytes,
    Held? held,
  }) => verifyBundle(
    manifest: manifest,
    signature: signature,
    modules: modules,
    publicKey: publicKeyBytes ?? publicKey,
    held: held,
  );

  /// [f] signed with the test key and verified.
  Future<Bundle> verifySigned(Files f, {Held? held}) async =>
      verify(f.manifest, await sigFor(f.manifest), f.modules, held: held);

  group('verifyBundle: the signature', () {
    test(
      '1. each fixture protocol, signed, gives its manifest and modules',
      () async {
        for (final dir in protocolDirs()) {
          final f = filesIn(dir.path);
          final b = await verifySigned(f);
          final expected = parseManifest(readJson('${dir.path}/protocol.json'));
          expect(b.manifest.protocolId, expected.protocolId, reason: dir.path);
          expect(b.manifest.version, expected.version, reason: dir.path);
          expect(b.manifest.zone.name, expected.zone.name, reason: dir.path);
          expect(b.manifest.base, expected.base, reason: dir.path);
          expect(b.manifest.optional, expected.optional, reason: dir.path);
          final modules = [
            for (final bytes in f.modules)
              parseModule(
                jsonDecode(utf8.decode(bytes)) as Map<String, Object?>,
              ),
          ];
          expect(
            b.modules.keys,
            unorderedEquals([
              expected.base.moduleId,
              for (final ref in expected.optional) ref.moduleId,
            ]),
            reason: dir.path,
          );
          for (final m in modules) {
            expect(
              b.modules[m.moduleId]!.version,
              m.version,
              reason: m.moduleId,
            );
            expect(b.modules[m.moduleId]!.steps, m.steps, reason: m.moduleId);
          }
        }
      },
    );

    group('2. a missing or malformed protocol.sig is unsigned', () {
      for (final (name, make) in <(String, List<int>? Function(List<int>))>[
        ('missing', (_) => null),
        ('empty', (_) => const []),
        ('with a trailing newline', (s) => [...sigText(s), 0x0a]),
        ('with CRLF', (s) => [...sigText(s), 0x0d, 0x0a]),
        ('with a leading space', (s) => [0x20, ...sigText(s)]),
        ('87 characters', (s) => sigText(s).sublist(0, 87)),
        ('without padding', (s) => sigText(s).sublist(0, 86)),
        ('URL-safe alphabet', (s) => [0x2d, ...sigText(s).sublist(1)]),
        ('not base64', (s) => [0x2a, ...sigText(s).sublist(1)]),
        ('not ASCII', (s) => [0xff, ...sigText(s).sublist(1)]),
        // The decoded bytes are the same, so a lax decoder would accept it.
        (
          'non-zero padding bits',
          (s) => [...sigText(s).sublist(0, 85), sigText(s)[85] + 1, 0x3d, 0x3d],
        ),
        ('63 bytes', (s) => sigText(s.sublist(0, 63))),
        ('65 bytes', (s) => sigText([...s, 0])),
        ('66 bytes', (s) => sigText([...s, 0, 0])),
      ]) {
        test(name, () async {
          final f = files(umms);
          final sig = make(await signatureOf(f.manifest));
          await expectLater(
            verify(f.manifest, sig, f.modules),
            refused(BundleRefusal.unsigned),
          );
        });
      }
    });

    test('3. signed by another key is a bad signature', () async {
      final f = files(umms);
      await expectLater(
        verify(f.manifest, await sigFor(f.manifest, otherKey), f.modules),
        refused(BundleRefusal.badSignature),
      );
    });

    test('4. any one manifest byte changed is a bad signature', () async {
      final f = files(umms);
      final sig = await sigFor(f.manifest);
      final notRefused = <int>[];
      for (var i = 0; i < f.manifest.length; i++) {
        final changed = [...f.manifest]..[i] ^= 0x01;
        final reason = await refusal(() => verify(changed, sig, f.modules));
        if (reason != BundleRefusal.badSignature) notRefused.add(i);
      }
      expect(notRefused, isEmpty);
    });

    test('5. the time zone changed is a bad signature', () async {
      final f = files(umms);
      final changed = edit(f.manifest, 'America/New_York', 'America/Chicago');
      await expectLater(
        verify(changed, await sigFor(f.manifest), f.modules),
        refused(BundleRefusal.badSignature),
      );
    });

    test('6. any one signature bit flipped is a bad signature', () async {
      final f = files(umms);
      final signature = await signatureOf(f.manifest);
      final notRefused = <int>[];
      for (var bit = 0; bit < 64 * 8; bit++) {
        final flipped = [...signature]..[bit ~/ 8] ^= 1 << (bit % 8);
        final reason = await refusal(
          () => verify(f.manifest, sigText(flipped), f.modules),
        );
        if (reason != BundleRefusal.badSignature) notRefused.add(bit);
      }
      expect(notRefused, isEmpty);
    });

    group('7. the same manifest reformatted is a bad signature', () {
      for (final (name, reformat) in <(String, List<int> Function(List<int>))>[
        ('compact', (m) => utf8.encode(jsonEncode(jsonDecode(utf8.decode(m))))),
        (
          'four-space indent',
          (m) => utf8.encode(
            const JsonEncoder.withIndent('    ')
                .convert(jsonDecode(utf8.decode(m))),
          ),
        ),
        (
          'CRLF line endings',
          (m) => utf8.encode(utf8.decode(m).replaceAll('\n', '\r\n')),
        ),
        ('no final newline', (m) => m.sublist(0, m.length - 1)),
      ]) {
        test(name, () async {
          final f = files(umms);
          final changed = reformat(f.manifest);
          expect(changed, isNot(f.manifest));
          await expectLater(
            verify(changed, await sigFor(f.manifest), f.modules),
            refused(BundleRefusal.badSignature),
          );
        });
      }
    });

    group('8. a signature over any other message is a bad signature', () {
      for (final (name, message) in <(String, List<int> Function(List<int>))>[
        ('the raw manifest bytes', (m) => m),
        ('the SHA-256 without the label', (m) => sha256.convert(m).bytes),
        (
          'another label version',
          (m) => [
            ...ascii.encode('prep-timeline/manifest/v2'),
            ...sha256.convert(m).bytes,
          ],
        ),
        (
          'the label and the hex SHA-256',
          (m) => [...label, ...ascii.encode(hexSha(m))],
        ),
        ('the label and the raw bytes', (m) => [...label, ...m]),
      ]) {
        test(name, () async {
          final f = files(umms);
          final sig = sigText(await rawSign(message(f.manifest)));
          await expectLater(
            verify(f.manifest, sig, f.modules),
            refused(BundleRefusal.badSignature),
          );
        });
      }
    });

    test('9. a non-canonical S (S + L) is a bad signature', () async {
      final f = files(umms);
      final sig = sigText(nonCanonicalS(await signatureOf(f.manifest)));
      await expectLater(
        verify(f.manifest, sig, f.modules),
        refused(BundleRefusal.badSignature),
      );
    });

    group('10. a public key that is not 32 bytes is an ArgumentError', () {
      for (final length in const [0, 31, 33]) {
        test('$length bytes', () async {
          final f = files(umms);
          await expectLater(
            verify(
              f.manifest,
              await sigFor(f.manifest),
              f.modules,
              publicKeyBytes: List.filled(length, 1),
            ),
            throwsArgumentError,
          );
        });
      }

      // With protocol.sig missing the library never sees the key, so only
      // our own length check can reject it.
      for (final length in const [1, 33]) {
        test('$length bytes, even with protocol.sig missing', () async {
          final f = files(umms);
          await expectLater(
            verify(
              f.manifest,
              null,
              f.modules,
              publicKeyBytes: List.filled(length, 1),
            ),
            throwsArgumentError,
          );
        });
      }
    });
  });

  group('verifyBundle: the modules', () {
    for (final (name, alter)
        in <(String, List<List<int>> Function(List<List<int>>, int))>[
          (
            '11. a listed module that is missing is not matched, by name',
            (m, i) => [...m]..removeAt(i),
          ),
          (
            '12. one module byte changed is not matched, by name',
            (m, i) => [...m]..[i] = ([...m[i]]..[m[i].length ~/ 2] ^= 0x01),
          ),
        ]) {
      group(name, () {
        final f = files(uw);
        for (var i = 0; i < f.modules.length; i++) {
          final id = moduleIdOf(f.modules[i]);
          test(id, () async {
            await expectLater(
              verify(f.manifest, await sigFor(f.manifest), alter(f.modules, i)),
              refused(BundleRefusal.moduleNotMatched, id),
            );
          });
        }
      });
    }

    test('13. the wrong-hash-ccf fixture, signed, is not matched', () async {
      final f = filesIn('../../fixtures/invalid/wrong-hash-ccf');
      await expectLater(
        verifySigned(f),
        refused(BundleRefusal.moduleNotMatched, 'wrong-hash-ccf-base'),
      );
    });

    group('14. an unlisted file is refused, and never parsed', () {
      for (final (name, extra) in <(String, List<int> Function())>[
        ('a module from another protocol', () => files(umms).modules.first),
        ('not JSON', () => ascii.encode('not json')),
      ]) {
        test(name, () async {
          final f = files(uw);
          await expectLater(
            verify(f.manifest, await sigFor(f.manifest), [
              ...f.modules,
              extra(),
            ]),
            refused(BundleRefusal.unlistedFile),
          );
        });
      }
    });

    test('15. the same file passed twice is an unlisted file', () async {
      final f = files(uw);
      await expectLater(
        verify(f.manifest, await sigFor(f.manifest), [
          ...f.modules,
          f.modules.first,
        ]),
        refused(BundleRefusal.unlistedFile),
      );
    });

    group(
      '16. a module whose hash matches but whose ID or version differs',
      () {
        const ironHold = '$umms-iron-hold';
        for (final (name, from, to) in const [
          ('version', '"version": 1,', '"version": 2,'),
          ('moduleId', '"moduleId": "$ironHold"', '"moduleId": "$ironHold-x"'),
        ]) {
          test(name, () async {
            final f = files(umms);
            final i = f.modules.indexWhere(
              (m) => utf8.decode(m).contains('"moduleId": "$ironHold"'),
            );
            final changed = edit(f.modules[i], from, to);
            final manifest = edit(
              f.manifest,
              hexSha(f.modules[i]),
              hexSha(changed),
            );
            final modules = [...f.modules]..[i] = changed;
            await expectLater(
              verify(manifest, await sigFor(manifest), modules),
              refused(BundleRefusal.moduleMismatch, ironHold),
            );
          });
        }
      },
    );
  });

  group('verifyBundle: the version held', () {
    /// UMMC's manifest at version 2, otherwise unchanged.
    List<int> version2(List<int> manifest) => edit(
      manifest,
      '"protocolId": "$umms",\n  "version": 1,',
      '"protocolId": "$umms",\n  "version": 2,',
    );

    test('17. an older version than the one held is refused', () async {
      final f = files(umms);
      final held = (
        protocolId: umms,
        version: 2,
        sha256: hexSha(version2(f.manifest)),
      );
      await expectLater(
        verifySigned(f, held: held),
        refused(BundleRefusal.olderVersion),
      );
    });

    test('18. the same version with the same bytes is accepted', () async {
      final f = files(umms);
      final held = (protocolId: umms, version: 1, sha256: hexSha(f.manifest));
      final b = await verifySigned(f, held: held);
      expect(b.manifest.version, 1);
    });

    test('19. the same version with different bytes is refused', () async {
      final f = files(umms);
      final held = (protocolId: umms, version: 1, sha256: '0' * 64);
      await expectLater(
        verifySigned(f, held: held),
        refused(BundleRefusal.changedVersion),
      );
    });

    test('20. a newer version is accepted', () async {
      final f = files(umms);
      final manifest = version2(f.manifest);
      final held = (protocolId: umms, version: 1, sha256: hexSha(f.manifest));
      final b = await verifySigned((
        manifest: manifest,
        modules: f.modules,
      ), held: held);
      expect(b.manifest.version, 2);
    });

    test(
      '21. a held record for another protocol is an ArgumentError',
      () async {
        final f = files(umms);
        final held = (protocolId: uw, version: 1, sha256: hexSha(f.manifest));
        await expectLater(verifySigned(f, held: held), throwsArgumentError);
      },
    );
  });

  group('verifyBundle: order of checks', () {
    test(
      '22. a bad signature comes before an older version and a missing module',
      () async {
        final f = files(umms);
        final held = (protocolId: umms, version: 2, sha256: '0' * 64);
        await expectLater(
          verify(
            f.manifest,
            await sigFor(f.manifest, otherKey),
            f.modules.sublist(1),
            held: held,
          ),
          refused(BundleRefusal.badSignature),
        );
      },
    );

    test('23. an older version comes before a missing module', () async {
      final f = files(umms);
      final held = (protocolId: umms, version: 2, sha256: '0' * 64);
      await expectLater(
        verify(
          f.manifest,
          await sigFor(f.manifest),
          f.modules.sublist(1),
          held: held,
        ),
        refused(BundleRefusal.olderVersion),
      );
    });

    group('24. a manifest that fails the signature is never parsed', () {
      for (final (name, garbage) in <(String, List<int>)>[
        ('not JSON', ascii.encode('not json')),
        ('not UTF-8', const [0xff, 0xfe]),
      ]) {
        test('$name, unsigned', () async {
          await expectLater(
            verify(garbage, null, const []),
            refused(BundleRefusal.unsigned),
          );
        });

        test('$name, signed for another manifest', () async {
          final sig = await sigFor(files(umms).manifest);
          await expectLater(
            verify(garbage, sig, const []),
            refused(BundleRefusal.badSignature),
          );
        });
      }
    });

    group('25. a signed manifest that is malformed is a FormatException', () {
      for (final (name, manifest) in <(String, List<int>)>[
        ('not JSON', ascii.encode('not json')),
        ('not UTF-8', const [0xff, 0xfe]),
        ('a JSON array', ascii.encode('[]')),
        ('an empty object', ascii.encode('{}')),
      ]) {
        test(name, () async {
          await expectLater(
            verify(manifest, await sigFor(manifest), const []),
            throwsFormatException,
          );
        });
      }
    });

    group('26. a signed module that is malformed is a FormatException', () {
      for (final (name, module) in <(String, List<int>)>[
        ('not JSON', ascii.encode('not json')),
        ('a JSON array', ascii.encode('[]')),
        ('an empty object', ascii.encode('{}')),
      ]) {
        test(name, () async {
          final f = files(umms);
          final i = f.modules.indexWhere(
            (m) => utf8.decode(m).contains('"moduleId": "$umms-iron-hold"'),
          );
          final manifest = edit(
            f.manifest,
            hexSha(f.modules[i]),
            hexSha(module),
          );
          final modules = [...f.modules]..[i] = module;
          await expectLater(
            verify(manifest, await sigFor(manifest), modules),
            throwsFormatException,
          );
        });
      }
    });
  });

  test('27. a verified bundle feeds selection as before', () async {
    final b = await verifySigned(files(umms));
    final qr = decodeQr(
      {
        'protocolId': umms,
        'version': 1,
        'stage': 'scheduling',
        'modules': ['$umms-iron-hold'],
        'parameters': <String, Object?>{},
        'createdAt': '2026-11-01T14:00:00Z',
      },
      b.manifest,
      b.modules,
    );
    final result = selectedModules(
      b.manifest,
      b.modules,
      qr,
      null,
      local('America/New_York', 2026, 11, 18, 8),
      now: local('America/New_York', 2026, 11, 2, 9),
    );
    expect(result, isA<Selected>());
    expect(
      [for (final s in (result as Selected).modules) s.module.moduleId],
      ['$umms-base', '$umms-iron-hold'],
    );
  });

  test(
    '28. a signed manifest listing a moduleId twice is a FormatException',
    () async {
      final f = files(umms);
      const ironHold = '$umms-iron-hold';
      final i = f.modules.indexWhere(
        (m) => utf8.decode(m).contains('"moduleId": "$ironHold"'),
      );
      // The same module with different bytes, so each listing matches a file.
      final copy = [...f.modules[i], 0x0a];
      final json = jsonDecode(utf8.decode(f.manifest)) as Map<String, Object?>;
      (json['optionalModules']! as List<Object?>).add({
        'moduleId': ironHold,
        'version': 1,
        'sha256': hexSha(copy),
        'selectedAt': 'scheduling',
      });
      final manifest = utf8.encode(jsonEncode(json));
      await expectLater(
        verify(manifest, await sigFor(manifest), [...f.modules, copy]),
        throwsFormatException,
      );
    },
  );
}
