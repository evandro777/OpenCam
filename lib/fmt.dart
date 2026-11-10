String two(int n) => n.toString().padLeft(2, '0');

/// "2026-11-09"
String ymd(DateTime t) => '${t.year}-${two(t.month)}-${two(t.day)}';

/// "16:04"
String hm(DateTime t) => '${two(t.hour)}:${two(t.minute)}';
