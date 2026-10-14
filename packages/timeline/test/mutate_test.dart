import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/mutate.dart';

void main() {
  group('parseMutants', () {
    const expected = (
      tests: ['test/clock_test.dart'],
      mutants: [
        (find: 'to < from', replace: 'to <= from', name: 'end included'),
        (find: 'x', replace: 'y', name: 'x to y'),
      ],
    );
    // Records compare lists by identity; a list of the fields compares them
    // element by element.
    List<Object> fields(MutantList list) => [list.tests, list.mutants];

    test('1. reads the tests line, then find, replace and name for each '
        'entry', () {
      expect(
        fields(
          parseMutants(
            '# Comment lines and blank lines between entries are skipped.\n'
            'tests: test/clock_test.dart\n'
            '\n'
            'find: to < from\n'
            'replace: to <= from\n'
            'name: end included\n'
            '\n'
            'find: x\n'
            'replace: y\n'
            'name: x to y\n',
          ),
        ),
        fields(expected),
      );
    });

    test('2. reads a list saved with CRLF line endings', () {
      expect(
        fields(
          parseMutants(
            'tests: test/clock_test.dart\r\n'
            '\r\n'
            'find: to < from\r\n'
            'replace: to <= from\r\n'
            'name: end included\r\n'
            '\r\n'
            'find: x\r\n'
            'replace: y\r\n'
            'name: x to y\r\n',
          ),
        ),
        fields(expected),
      );
    });

    test('3. drops only the one space after the key; replace may be empty', () {
      expect(
        parseMutants(
          'tests: test/a_test.dart\nfind:   a;  \nreplace:\nname: a dropped\n',
        ).mutants,
        [(find: '  a;  ', replace: '', name: 'a dropped')],
      );
    });

    test('14. keeps every test file on the tests line, in order', () {
      expect(
        parseMutants(
          'tests: test/protocol_test.dart test/reminder_test.dart\n'
          'find: a\nreplace: b\nname: n\n',
        ).tests,
        ['test/protocol_test.dart', 'test/reminder_test.dart'],
      );
    });

    // Every entry is otherwise valid, so each case fails for its own reason.
    const tests = 'tests: test/a_test.dart\n';
    const entry = 'find: a\nreplace: b\nname: n\n';
    const rejected = {
      'no entries': '$tests# nothing here\n',
      'a missing name': '${tests}find: a\nreplace: b\n',
      'keys out of order': '${tests}replace: b\nfind: a\nname: n\n',
      'an unknown key': '$tests${entry}note: x\n',
      'a line without a key': '$tests${entry}stray\n',
      'an empty find': '${tests}find:\nreplace: b\nname: n\n',
      'an empty name': '${tests}find: a\nreplace: b\nname:\n',
      'a replacement equal to find': '${tests}find: a\nreplace: a\nname: n\n',
      'two mutants with one name':
          '$tests$entry\nfind: c\nreplace: d\nname: n\n',
      'no tests line': entry,
      'a tests line after an entry': '$entry\n$tests',
      'two tests lines': '$tests${tests}$entry',
      'an empty tests line': 'tests:\n$entry',
      'a test file outside test/': 'tests: tool/a_test.dart\n$entry',
      'a test file in a folder under test/':
          'tests: test/sub/a_test.dart\n$entry',
      'a file that is not a _test.dart file':
          'tests: test/support.dart\n$entry',
      'two spaces between test files':
          'tests: test/a_test.dart  test/b_test.dart\n$entry',
      'a test file named twice':
          'tests: test/a_test.dart test/a_test.dart\n$entry',
    };
    rejected.forEach((what, text) {
      test('4. rejects $what', () {
        expect(() => parseMutants(text), throwsFormatException);
      });
    });
  });

  group('applyMutant', () {
    const source = 'a\r\nfinal wraps = to < from;\r\nb\n';

    test('5. replaces the one occurrence and keeps every line ending', () {
      expect(
        applyMutant(source, (
          find: 'to < from',
          replace: 'to <= from',
          name: 'n',
        )),
        'a\r\nfinal wraps = to <= from;\r\nb\n',
      );
    });

    test('6. rejects text the source does not contain', () {
      expect(
        () => applyMutant(source, (find: 'to > from', replace: 'x', name: 'n')),
        throwsFormatException,
      );
    });

    test('7. rejects text the source contains twice', () {
      expect(
        () => applyMutant(source, (find: 'a', replace: 'x', name: 'n')),
        throwsFormatException,
      );
    });
  });

  group('testMutant', () {
    // Mixed line endings, a non-ASCII character and no final newline: every
    // byte must survive the round trip.
    final original = utf8.encode('// café\r\nconst a = 1 < 2;\nconst b = 3;');
    const mutant = (find: '1 < 2', replace: '1 <= 2', name: 'n');
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('mutate_test');
      file = File('${dir.path}/source.dart')..writeAsBytesSync(original);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('8. tests the mutated file, then restores it byte for byte', () async {
      String? seen;
      final outcome = await testMutant(file, original, mutant, () async {
        seen = file.readAsStringSync();
        return Outcome.survived;
      });
      expect(seen, '// café\r\nconst a = 1 <= 2;\nconst b = 3;');
      expect(outcome, Outcome.survived);
      expect(file.readAsBytesSync(), original);
    });

    test('9. restores the file when the test run throws', () async {
      await expectLater(
        testMutant(file, original, mutant, () => throw StateError('crashed')),
        throwsStateError,
      );
      expect(file.readAsBytesSync(), original);
    });
  });

  group('runTests', () {
    late Directory dir;
    late String script;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('mutate_test');
      script = '${dir.path}/fake_tests.dart';
      File(script).writeAsStringSync('''
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.first == 'hang') await Future<void>.delayed(const Duration(minutes: 5));
  exit(int.parse(args.first));
}
''');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<Outcome> run(String arg, Duration timeout) => runTests(
      [Platform.resolvedExecutable, script, arg],
      workingDirectory: dir.path,
      timeout: timeout,
    );

    test('10. tests pass: survived', () async {
      expect(await run('0', const Duration(minutes: 1)), Outcome.survived);
    });

    test('11. tests fail: killed', () async {
      expect(await run('1', const Duration(minutes: 1)), Outcome.killed);
    });

    test('12. tests still running at the timeout: timed out', () async {
      expect(await run('hang', const Duration(seconds: 3)), Outcome.timedOut);
    });
  });

  group('table', () {
    test('13. one row per mutant, then totals; timed out counts as killed', () {
      expect(
        table([
          (source: 'clock.dart', name: 'a || b', outcome: Outcome.killed),
          (source: 'clock.dart', name: 'b', outcome: Outcome.survived),
          (source: 'offset.dart', name: 'c', outcome: Outcome.timedOut),
        ]),
        '| Source | Mutant | Result |\n'
        '| --- | --- | --- |\n'
        r'| clock.dart | a \|\| b | killed |'
        '\n'
        '| clock.dart | b | survived |\n'
        '| offset.dart | c | timed out |\n'
        '\n'
        'clock.dart: 2 mutants, 1 killed (0 timed out), 1 survived\n'
        'offset.dart: 1 mutants, 1 killed (1 timed out), 0 survived\n'
        'total: 3 mutants, 2 killed (1 timed out), 1 survived\n',
      );
    });
  });
}
