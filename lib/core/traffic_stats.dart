import 'dart:math';

/// 一天的流量
class TrafficDay {
  final String date;
  final int upload;
  final int download;

  const TrafficDay(this.date, this.upload, this.download);
}

/// 按天累计的流量。只记总量，不记访问了什么，所以不需要脱敏
class TrafficStats {
  final Map<String, List<int>> _days;

  /// 上次读到的内核累计值。内核只给启动以来的总量，要自己算差值
  int _lastUpload;
  int _lastDownload;

  TrafficStats({Map<String, List<int>>? days, int lastUpload = 0, int lastDownload = 0})
      : _days = days ?? {},
        _lastUpload = lastUpload,
        _lastDownload = lastDownload;

  static String _dateOf(DateTime time) => time.toIso8601String().substring(0, 10);

  /// 内核重启后累计值从零开始，比上次小时就全算新增
  void record(int uploadTotal, int downloadTotal, DateTime now, {required int keepDays}) {
    final up = uploadTotal < _lastUpload ? uploadTotal : uploadTotal - _lastUpload;
    final down = downloadTotal < _lastDownload ? downloadTotal : downloadTotal - _lastDownload;
    _lastUpload = uploadTotal;
    _lastDownload = downloadTotal;

    final day = _days.putIfAbsent(_dateOf(now), () => [0, 0]);
    day[0] += up;
    day[1] += down;

    final oldest = _dateOf(now.subtract(Duration(days: max(keepDays, 1) - 1)));
    _days.removeWhere((date, _) => date.compareTo(oldest) < 0);
  }

  /// 新的在前
  List<TrafficDay> get days {
    final dates = _days.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final date in dates) TrafficDay(date, _days[date]![0], _days[date]![1])];
  }

  void clear() => _days.clear();

  factory TrafficStats.fromJson(Map<String, dynamic> json) => TrafficStats(
        days: (json['days'] as Map?)?.map(
          (key, value) => MapEntry(key.toString(), (value as List).map((e) => e as int).toList()),
        ),
        lastUpload: json['lastUpload'] ?? 0,
        lastDownload: json['lastDownload'] ?? 0,
      );

  Map<String, dynamic> toJson() => {'days': _days, 'lastUpload': _lastUpload, 'lastDownload': _lastDownload};
}
