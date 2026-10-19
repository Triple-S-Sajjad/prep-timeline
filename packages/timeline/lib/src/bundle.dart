import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart'
    show KeyPairType, Signature, SimplePublicKey;
import 'package:cryptography/dart.dart' show DartEd25519;

import 'protocol.dart';

/// A protocol whose signature, version and module hashes have been checked.
/// Only [verifyBundle] makes one, so nothing unverified reaches selection.
final class Bundle {
  Bundle._(this.manifest, Map<String, Module> modules)
    : modules = Map.unmodifiable(modules);
  final Manifest manifest;
  final Map<String, Module> modules;
}

/// The version the app already holds, with its manifest's SHA-256 in
/// lowercase hex.
typedef Held = ({String protocolId, int version, String sha256});

enum BundleRefusal {
  unsigned,
  badSignature,
  olderVersion,
  changedVersion,
  moduleNotMatched,
  unlistedFile,
  moduleMismatch,
}

/// "The patient app refuses any unsigned or mis-signed bundle." [moduleId]
/// names the listed module for moduleNotMatched and moduleMismatch.
final class BundleRefused implements Exception {
  const BundleRefused(this.reason, [this.moduleId]);
  final BundleRefusal reason;
  final String? moduleId;
}

/// The signed message is this label, then the manifest's 32-byte SHA-256.
final _label = ascii.encode('prep-timeline/manifest/v1');

/// Canonical base64 of 64 bytes: the last character before the padding
/// carries 2 bits and 4 zero bits, so a lax decoder can't accept 4 spellings
/// of one signature.
final _sigText = RegExp(r'^[A-Za-z0-9+/]{85}[AQgw]==$');

/// Checks the bundle's files and returns its manifest and modules, or throws
/// [BundleRefused]. [signature] is protocol.sig's bytes, null when absent.
/// Throws ArgumentError for a [publicKey] that isn't 32 bytes or a [held]
/// record for another protocol, and FormatException for signed content that
/// doesn't parse.
Future<Bundle> verifyBundle({
  required List<int> manifest,
  required List<int>? signature,
  required List<List<int>> modules,
  required List<int> publicKey,
  Held? held,
}) async {
  if (publicKey.length != 32) {
    throw ArgumentError.value(publicKey.length, 'publicKey', 'Not 32 bytes');
  }
  final digest = sha256.convert(manifest);
  // Pure Dart everywhere, browsers included: it is the implementation the
  // tests check, including its rejection of a non-canonical S.
  final signed = await DartEd25519().verify(
    [..._label, ...digest.bytes],
    signature: Signature(
      _signatureBytes(signature),
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    ),
  );
  if (!signed) throw const BundleRefused(BundleRefusal.badSignature);

  final parsed = manifestOf(manifest);
  if (held != null) {
    if (held.protocolId != parsed.protocolId) {
      throw ArgumentError.value(held.protocolId, 'held', 'Another protocol');
    }
    if (parsed.version < held.version) {
      throw const BundleRefused(BundleRefusal.olderVersion);
    }
    // Published versions are immutable.
    if (parsed.version == held.version && digest.toString() != held.sha256) {
      throw const BundleRefused(BundleRefusal.changedVersion);
    }
  }

  return Bundle._(parsed, matchModules(parsed, modules));
}

/// [manifest]'s bytes, parsed. Throws FormatException for content that
/// doesn't parse.
Manifest manifestOf(List<int> manifest) => parseManifest(_object(manifest));

/// The modules [parsed] lists, matched to the [modules] files by SHA-256 and
/// parsed, by module ID. Checks no signature: [verifyBundle] calls it after
/// checking one, and the publish check on content not yet signed. Throws
/// [BundleRefused] with moduleNotMatched, unlistedFile or moduleMismatch,
/// and FormatException for content that doesn't parse or a module listed
/// twice.
Map<String, Module> matchModules(Manifest parsed, List<List<int>> modules) {
  final files = [
    for (final bytes in modules)
      (sha256: sha256.convert(bytes).toString(), bytes: bytes),
  ];
  final matched = <(ModuleRef, List<int>)>[];
  for (final ref in [parsed.base, ...parsed.optional]) {
    final i = files.indexWhere((f) => f.sha256 == ref.sha256);
    if (i < 0) {
      throw BundleRefused(BundleRefusal.moduleNotMatched, ref.moduleId);
    }
    matched.add((ref, files.removeAt(i).bytes));
  }
  if (files.isNotEmpty) throw const BundleRefused(BundleRefusal.unlistedFile);

  final byId = <String, Module>{};
  for (final (ref, bytes) in matched) {
    final module = parseModule(_object(bytes));
    if (module.moduleId != ref.moduleId || module.version != ref.version) {
      throw BundleRefused(BundleRefusal.moduleMismatch, ref.moduleId);
    }
    if (byId.containsKey(ref.moduleId)) {
      throw FormatException('Listed twice', ref.moduleId);
    }
    byId[ref.moduleId] = module;
  }
  return byId;
}

List<int> _signatureBytes(List<int>? file) {
  final text = file == null ? '' : String.fromCharCodes(file);
  if (!_sigText.hasMatch(text)) {
    throw const BundleRefused(BundleRefusal.unsigned);
  }
  return base64.decode(text);
}

Map<String, Object?> _object(List<int> bytes) =>
    switch (jsonDecode(utf8.decode(bytes))) {
      final Map<String, Object?> json => json,
      final other => throw FormatException('Not a JSON object', other),
    };
