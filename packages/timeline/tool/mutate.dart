/// Mutation testing for lib/src. Run from packages/timeline:
///
///     dart run tool/mutate.dart [source ...]
///
/// Each tool/mutants/<source>.txt lists mutants of lib/src/<source>.dart;
/// naming sources runs only those lists. Every mutant is applied on its own,
/// `dart test` runs the test files the list names, and the file is put back
/// byte for byte before the next.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef Mutant = ({String find, String replace, String name});

typedef MutantList = ({List<String> tests, List<Mutant> mutants});

enum Outcome { killed, survived, timedOut }

typedef Result = ({String source, String name, Outcome outcome});

const _timeout = Duration(minutes: 5);

const _keys = ['find', 'replace', 'name'];

/// The first line that isn't a comment or blank is `tests:` and the test
/// files that cover the source, one space apart. Entries follow: `find:`,
/// `replace:` and `name:` lines in that order, separated by blank lines; `#`
/// lines are comments. One space after the colon is dropped, so a value can
/// keep its own leading spaces.
MutantList parseMutants(String text) {
  List<String>? tests;
  final mutants = <Mutant>[];
  var values = <String>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.startsWith('#') || (line.isEmpty && values.isEmpty)) continue;
    if (tests == null) {
      tests = _tests(line);
      continue;
    }
    if (line.isEmpty) {
      throw FormatException('Entry ends before "${_keys[values.length]}:"');
    }
    if (values.length == _keys.length) {
      throw FormatException('Expected a blank line after "name:"', line);
    }
    final key = '${_keys[values.length]}:';
    if (!line.startsWith(key)) throw FormatException('Expected "$key"', line);
    final value = line.substring(key.length);
    values.add(value.startsWith(' ') ? value.substring(1) : value);
    if (values.length == _keys.length) {
      mutants.add(_mutant(values, mutants));
      values = [];
    }
  }
  if (values.isNotEmpty) {
    throw FormatException('Entry ends before "${_keys[values.length]}:"');
  }
  if (tests == null || mutants.isEmpty) {
    throw const FormatException('No mutants');
  }
  return (tests: tests, mutants: mutants);
}

final _testFile = RegExp(r'^test/[a-z0-9_]+_test\.dart$');

/// Required, with no fallback to the whole suite, so every list states which
/// tests cover its source.
List<String> _tests(String line) {
  const key = 'tests: ';
  if (!line.startsWith(key)) throw FormatException('Expected "$key"', line);
  final files = line.substring(key.length).split(' ');
  if (!files.every(_testFile.hasMatch) || files.toSet().length < files.length) {
    throw FormatException('Not distinct test/<name>_test.dart files', line);
  }
  return files;
}

Mutant _mutant(List<String> values, List<Mutant> earlier) {
  final [find, replace, name] = values;
  if (find.isEmpty || name.isEmpty) {
    throw FormatException('Empty find or name', name);
  }
  if (find == replace) throw FormatException('Replacement equals find', name);
  if (earlier.any((m) => m.name == name)) {
    throw FormatException('Name used twice', name);
  }
  return (find: find, replace: replace, name: name);
}

/// [source] with [mutant] applied. Its text must occur exactly once, so a
/// list can never silently mutate a different line than the one it means.
String applyMutant(String source, Mutant mutant) {
  final at = source.indexOf(mutant.find);
  if (at == -1 || source.indexOf(mutant.find, at + 1) != -1) {
    throw FormatException(
      'Must occur exactly once: "${mutant.find}"',
      mutant.name,
    );
  }
  return source.replaceRange(at, at + mutant.find.length, mutant.replace);
}

/// Writes [mutant] into [source], runs [runTests], and always writes
/// [original] back, checking that the file is byte-identical to it.
Future<Outcome> testMutant(
  File source,
  List<int> original,
  Mutant mutant,
  Future<Outcome> Function() runTests,
) async {
  source.writeAsStringSync(
    applyMutant(utf8.decode(original), mutant),
    flush: true,
  );
  try {
    return await runTests();
  } finally {
    source.writeAsBytesSync(original, flush: true);
    if (!_same(source.readAsBytesSync(), original)) {
      throw StateError(
        '${source.path} was not restored after "${mutant.name}"',
      );
    }
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Runs [command]; a run still going at [timeout] is killed and counts as
/// timed out, which the totals count as killed.
Future<Outcome> runTests(
  List<String> command, {
  required String workingDirectory,
  required Duration timeout,
}) async {
  final process = await Process.start(
    command.first,
    command.skip(1).toList(),
    workingDirectory: workingDirectory,
  );
  // Drained so a full output pipe can't stall the tests into a false timeout.
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.drain<void>());
  try {
    return await process.exitCode.timeout(timeout) == 0
        ? Outcome.survived
        : Outcome.killed;
  } on TimeoutException {
    process.kill();
    // Gone before the caller restores the file it was reading.
    await process.exitCode;
    return Outcome.timedOut;
  }
}

/// A Markdown table of [results], then totals per source and overall.
String table(List<Result> results) {
  final out = StringBuffer(
    '| Source | Mutant | Result |\n| --- | --- | --- |\n',
  );
  for (final r in results) {
    final name = r.name.replaceAll('|', r'\|');
    final outcome = r.outcome == Outcome.timedOut
        ? 'timed out'
        : r.outcome.name;
    out.writeln('| ${r.source} | $name | $outcome |');
  }
  out.writeln();
  for (final source in {for (final r in results) r.source}) {
    out.writeln(
      _totals(source, [
        for (final r in results)
          if (r.source == source) r.outcome,
      ]),
    );
  }
  out.writeln(_totals('total', [for (final r in results) r.outcome]));
  return out.toString();
}

String _totals(String label, List<Outcome> outcomes) {
  int count(Outcome o) => outcomes.where((x) => x == o).length;
  final timedOut = count(Outcome.timedOut);
  final killed = count(Outcome.killed) + timedOut;
  return '$label: ${outcomes.length} mutants, $killed killed '
      '($timedOut timed out), ${count(Outcome.survived)} survived';
}

Future<void> main(List<String> args) async {
  final lists = {
    for (final f in Directory('tool/mutants').listSync().whereType<File>())
      if (f.path.endsWith('.txt'))
        f.uri.pathSegments.last.replaceFirst(RegExp(r'\.txt$'), ''): f,
  };
  final unknown = args.where((a) => !lists.containsKey(a));
  if (unknown.isNotEmpty) {
    stderr.writeln('No mutant list for: ${unknown.join(', ')}');
    exitCode = 64;
    return;
  }

  // Every list is checked against its source before any file is touched.
  final plan =
      <
        ({
          String name,
          File file,
          List<int> original,
          List<String> tests,
          List<Mutant> mutants,
        })
      >[];
  for (final name in (args.isEmpty ? lists.keys.toList() : args)..sort()) {
    final file = File('lib/src/$name.dart');
    try {
      final original = file.readAsBytesSync();
      final (:tests, :mutants) = parseMutants(lists[name]!.readAsStringSync());
      for (final m in mutants) {
        applyMutant(utf8.decode(original), m);
      }
      plan.add((
        name: name,
        file: file,
        original: original,
        tests: tests,
        mutants: mutants,
      ));
    } on FormatException catch (e) {
      stderr.writeln('${lists[name]!.path}: ${e.message}: ${e.source}');
      exitCode = 1;
      return;
    } on FileSystemException catch (e) {
      stderr.writeln('${e.path}: ${e.message}');
      exitCode = 1;
      return;
    }
  }

  Future<Outcome> dartTest(List<String> tests) => runTests(
    [Platform.resolvedExecutable, 'test', ...tests],
    workingDirectory: Directory.current.path,
    timeout: _timeout,
  );
  // Also fails if a listed test file doesn't exist.
  final allTests = {for (final p in plan) ...p.tests}.toList()..sort();
  if (await dartTest(allTests) != Outcome.survived) {
    stderr.writeln(
      'dart test ${allTests.join(' ')} fails with no mutant applied; fix '
      'that first.',
    );
    exitCode = 1;
    return;
  }

  // Ctrl-C mid-run must not leave a mutant in lib/src.
  ({File file, List<int> original})? current;
  final interrupt = ProcessSignal.sigint.watch().listen((_) {
    if (current case (:final file, :final original)) {
      file.writeAsBytesSync(original, flush: true);
    }
    exit(130);
  });

  final results = <Result>[];
  final total = plan.fold(0, (n, p) => n + p.mutants.length);
  for (final (:name, :file, :original, :tests, :mutants) in plan) {
    current = (file: file, original: original);
    for (final m in mutants) {
      final outcome = await testMutant(
        file,
        original,
        m,
        () => dartTest(tests),
      );
      results.add((source: '$name.dart', name: m.name, outcome: outcome));
      stderr.writeln(
        '[${results.length}/$total] $name.dart ${m.name}: '
        '${outcome.name}',
      );
    }
  }
  current = null;
  await interrupt.cancel();
  stdout.write(table(results));
}
