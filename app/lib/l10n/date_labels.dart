/// Shared deterministic date/time helpers (I18N-PLAN §7). Local timezone,
/// numeric formats ONLY — identical output in both locales; surrounding
/// labels come from the catalog. Never intl/DateFormat, never locale-
/// dependent 12/24-hour behavior: 24-hour clock always.
library;

String _two(int v) => v.toString().padLeft(2, '0');

/// Fixed local HH:mm (24h). Use this instead of TimeOfDay.format(context).
String formatLocalClock(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// Fixed local YYYY-MM-DD HH:mm (management memory mtime).
String formatLocalStamp(DateTime d) =>
    '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
