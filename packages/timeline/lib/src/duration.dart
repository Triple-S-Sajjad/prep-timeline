/// Hours and minutes only, as the schema allows. Four digits per part keeps
/// values sane and behaves the same on the phone and in the browser.
final _elapsed = RegExp(r'^(-)?PT(?:(\d{1,4})H)?(?:(\d{1,4})M)?$');

Duration parseElapsed(String text) {
  final match = _elapsed.firstMatch(text);
  final hours = match?.group(2);
  final minutes = match?.group(3);
  if (match == null || (hours == null && minutes == null)) {
    throw FormatException('Not an hours-and-minutes duration', text);
  }
  final duration = Duration(
    hours: hours == null ? 0 : int.parse(hours),
    minutes: minutes == null ? 0 : int.parse(minutes),
  );
  return match.group(1) == null ? duration : -duration;
}
