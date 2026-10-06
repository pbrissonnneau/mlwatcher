/// "2h 05m", "12m", "45s".
String formatDuration(Duration d) {
  if (d.inHours >= 24) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours > 0) return '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

/// Epoch values are usually integers; keep decimals only when needed.
String formatNumber(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(1);
}
