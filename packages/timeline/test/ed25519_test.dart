import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:test/test.dart';

import 'support.dart';

/// What the `cryptography` package does, independent of our code: the
/// signing service (KMS) signs with standard Ed25519, so the phone must verify
/// standard Ed25519.
void main() {
  // The pure-Dart implementation, which the phone runs; browsers use Web
  // Crypto instead, which these tests don't cover.
  final ed25519 = DartEd25519();

  List<int> hex(String s) => [
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ];

  Future<bool> verify(List<int> message, List<int> signature, List<int> key) =>
      ed25519.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
        ),
      );

  // RFC 8032, section 7.1, tests 1 to 3.
  const vectors = [
    (
      seed: '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
      key: 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a', // gitleaks:allow
      message: '',
      signature: 'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
    ),
    (
      seed: '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
      key: '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c', // gitleaks:allow
      message: '72',
      signature: '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
    ),
    (
      seed: 'c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7',
      key: 'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025', // gitleaks:allow
      message: 'af82',
      signature: '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
    ),
  ];

  group('1. RFC 8032 test vectors 1 to 3', () {
    for (final (i, v) in vectors.indexed) {
      test('vector ${i + 1}: key, signature and verification', () async {
        final pair = await ed25519.newKeyPairFromSeed(hex(v.seed));
        expect((await pair.extractPublicKey()).bytes, hex(v.key));
        final signed = await ed25519.sign(hex(v.message), keyPair: pair);
        expect(signed.bytes, hex(v.signature));
        expect(
          await verify(hex(v.message), hex(v.signature), hex(v.key)),
          isTrue,
        );
      });

      test('vector ${i + 1}: an altered message fails', () async {
        final altered = [...hex(v.message), 0];
        expect(await verify(altered, hex(v.signature), hex(v.key)), isFalse);
      });
    }
  });

  test('2. a non-canonical S (S + L) on vector 1 is rejected', () async {
    final v = vectors.first;
    final signature = nonCanonicalS(hex(v.signature));
    expect(await verify(hex(v.message), signature, hex(v.key)), isFalse);
  });
}
