import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Loads the time zone database and returns New York; shared by the tests.
tz.Location loadNewYork() {
  tzdata.initializeTimeZones();
  return tz.getLocation('America/New_York');
}
