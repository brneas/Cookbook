class DurationSuggestion {
  const DurationSuggestion(this.minimum, this.maximum);
  final Duration minimum;
  final Duration? maximum;
}

List<DurationSuggestion> durationSuggestions(String text) {
  final regex = RegExp(
    r'\b(\d+)(?:\s*[-–]\s*(\d+))?\s*(hours?|hrs?|h|minutes?|mins?|min|seconds?|secs?|sec)\b',
    caseSensitive: false,
  );
  final matches = regex.allMatches(text).toList();
  final result = <DurationSuggestion>[];
  int unit(String s) => s.toLowerCase().startsWith('h')
      ? 3600
      : s.toLowerCase().startsWith('m')
      ? 60
      : 1;
  for (var i = 0; i < matches.length; i++) {
    final m = matches[i];
    // Avoid treating a tail of a decimal, fraction, or negative quantity as exact.
    if (m.start > 0 && RegExp(r'[\d./\-]').hasMatch(text[m.start - 1])) {
      continue;
    }
    final amount = int.tryParse(m[1]!);
    final upperAmount = m[2] == null ? null : int.tryParse(m[2]!);
    if (amount == null ||
        amount > 604800 ||
        m[2] != null && (upperAmount == null || upperAmount > 604800)) {
      continue;
    }
    var seconds = amount * unit(m[3]!);
    int? upper = upperAmount == null ? null : upperAmount * unit(m[3]!);
    var end = m.end;
    var previousUnit = unit(m[3]!);
    while (upper == null && i + 1 < matches.length) {
      final next = matches[i + 1];
      if (next[2] != null ||
          unit(next[3]!) >= previousUnit ||
          !RegExp(
            r'^\s*(?:and\s*)?$',
          ).hasMatch(text.substring(end, next.start))) {
        break;
      }
      final nextAmount = int.tryParse(next[1]!);
      if (nextAmount == null || nextAmount > 604800) {
        seconds = 604801;
        i++;
        break;
      }
      seconds += nextAmount * unit(next[3]!);
      end = next.end;
      previousUnit = unit(next[3]!);
      i++;
    }
    if (seconds <= 0 ||
        seconds > 7 * 86400 ||
        upper != null && (upper < seconds || upper > 7 * 86400)) {
      continue;
    }
    result.add(
      DurationSuggestion(
        Duration(seconds: seconds),
        upper == null ? null : Duration(seconds: upper),
      ),
    );
  }
  return result;
}

String durationLabel(Duration duration) {
  final seconds = duration.inSeconds;
  return [
    if (seconds >= 3600) '${seconds ~/ 3600} hr',
    if (seconds % 3600 >= 60) '${seconds % 3600 ~/ 60} min',
    if (seconds % 60 != 0 || seconds == 0) '${seconds % 60} sec',
  ].join(' ');
}

String spokenDuration(Duration duration) => durationLabel(duration)
    .replaceAll('hr', 'hours')
    .replaceAll('min', 'minutes')
    .replaceAll('sec', 'seconds');
