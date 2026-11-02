import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/connection_log.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/network/bin/configuration.dart';

import 'connections_page.dart';
import 'design.dart';
import 'format.dart';

/// 首页的数字。默认只显示速度，其余的用户自己选：
/// 首页要保持干净，而且这些数字都要定时刷新，选得越少越省电
class HomeStats extends StatefulWidget {
  final CoreManager manager;
  final Configuration configuration;

  const HomeStats(this.manager, this.configuration, {super.key});

  @override
  State<HomeStats> createState() => _HomeStatsState();
}

class _HomeStatsState extends State<HomeStats> with WidgetsBindingObserver {
  static const Duration _tick = Duration(seconds: 1);

  /// 查连接要内核把所有连接序列化一遍，比时钟走得慢一些
  static const int _ticksPerSnapshot = 2;

  StreamSubscription<TrafficSample>? _traffic;
  Timer? _timer;
  int _ticks = 0;
  TrafficSample _sample = const TrafficSample(0, 0);

  /// 最近一分钟的速度，画曲线用
  static const int _speedHistory = 60;
  final List<TrafficSample> _speeds = [];
  ConnectionSnapshot? _snapshot;
  String? _outbound;
  String? _outboundFor;

  CoreManager get _manager => widget.manager;

  List<String> get _stats => _manager.settings.homeStats;

  bool get _needsSnapshot => _stats.any(const {HomeStat.connections, HomeStat.traffic, HomeStat.memory}.contains);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resume();
  }

  /// App 进后台时全部停掉：iOS 上这些请求一直占着内核的内存，也让解密时的主 App 多醒
  void _resume() {
    if (_stats.contains(HomeStat.speed)) {
      _traffic ??= _manager.api.traffic().listen((sample) {
        if (!mounted) return;
        setState(() {
          _sample = sample;
          _speeds.add(sample);
          if (_speeds.length > _speedHistory) _speeds.removeAt(0);
        });
      }, onError: (_) {});
    }
    if (_stats.contains(HomeStat.runtime) || _needsSnapshot) {
      _timer ??= Timer.periodic(_tick, (_) => _onTick());
    }
    if (_needsSnapshot) unawaited(_loadSnapshot());
    _refreshOutbound();
  }

  void _pause() {
    _traffic?.cancel();
    _traffic = null;
    _timer?.cancel();
    _timer = null;
  }

  void _onTick() {
    _ticks++;
    if (_needsSnapshot && _ticks % _ticksPerSnapshot == 0) unawaited(_loadSnapshot());
    if (_stats.contains(HomeStat.runtime) && mounted) setState(() {});
  }

  Future<void> _loadSnapshot() async {
    try {
      final snapshot = await _manager.api.connections();
      if (mounted) setState(() => _snapshot = snapshot);
    } on Exception {
      // 内核刚好在重启，下一轮再取
    }
  }

  /// 只在选了这一项、并且节点换了时才查：每次都要经节点访问外网
  void _refreshOutbound() {
    final proxy = _manager.proxyAddress;
    if (!_stats.contains(HomeStat.outboundIp) || proxy == null) return;
    final key = _manager.selectedNode ?? '';
    if (key == _outboundFor) return;
    _outboundFor = key;
    CoreTools.outboundAddress(proxy).then((address) {
      if (mounted) setState(() => _outbound = address);
    }, onError: (_) {
      if (mounted) setState(() => _outbound = '查询失败');
    });
  }

  @override
  void didUpdateWidget(HomeStats oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pause();
    _resume();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    state == AppLifecycleState.resumed ? _resume() : _pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pause();
    super.dispose();
  }

  Widget? _tile(String stat) {
    final snapshot = _snapshot;
    final started = _manager.settings.connectedAt;
    return switch (stat) {
      HomeStat.runtime => _Tile(
          '运行时长',
          started == null ? '--' : ConnectionView.formatDuration(DateTime.now().difference(started)),
        ),
      HomeStat.connections => _Tile(
          '连接',
          snapshot == null ? '--' : '${snapshot.connections.length}',
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => ConnectionsPage(configuration: widget.configuration))),
          onLongPress: () => _manager.api.closeAllConnections().catchError((_) {}),
        ),
      HomeStat.traffic => _Tile(
          '总流量',
          snapshot == null ? '--' : '↑ ${formatBytes(snapshot.uploadTotal)}\n↓ ${formatBytes(snapshot.downloadTotal)}',
        ),
      HomeStat.memory => _Tile('内存', snapshot == null ? '--' : formatBytes(snapshot.memory)),
      HomeStat.outboundIp => _Tile(
          '出口 IP',
          _outbound ?? '查询中',
          onTap: () {
            final address = _outbound;
            if (address == null) return;
            Clipboard.setData(ClipboardData(text: address.split(' ').first));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
          },
        ),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final tiles = _stats.map(_tile).nonNulls.toList();
    final speed = _stats.contains(HomeStat.speed);
    if (tiles.isEmpty && !speed) return const SizedBox.shrink();
    return Column(children: [
      if (speed) _SpeedCard(_sample, _speeds),
      if (speed && tiles.isNotEmpty) const SizedBox(height: AppTheme.gap),
      if (tiles.isNotEmpty)
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = AppTheme.gap;
            final width = (constraints.maxWidth - gap) / 2;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final tile in tiles) SizedBox(width: width, child: tile)],
            );
          },
        ),
    ]);
  }
}

/// 当前速度和最近一分钟的曲线
class _SpeedCard extends StatelessWidget {
  static const Color _downColor = Tone.teal;

  final TrafficSample sample;
  final List<TrafficSample> history;

  const _SpeedCard(this.sample, this.history);

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final style = Theme.of(context).textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    Widget rate(IconData icon, Color color, int value) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 4),
          Flexible(child: Text('${formatBytes(value)}/s', maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
        ]);

    return Panel(padding: const EdgeInsets.fromLTRB(14, 12, 14, 12), children: [
      Row(children: [
        SizedBox(
          width: 124,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            rate(Icons.arrow_upward, accent, sample.up),
            const SizedBox(height: 8),
            rate(Icons.arrow_downward, _downColor, sample.down),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 50,
            child: CustomPaint(painter: _SpeedPainter(history, up: accent, down: _downColor)),
          ),
        ),
      ]),
    ]);
  }
}

class _SpeedPainter extends CustomPainter {
  final List<TrafficSample> history;
  final Color up;
  final Color down;

  /// 新数据从右边进来，画布按满一分钟算
  static const int _slots = 60;

  _SpeedPainter(this.history, {required this.up, required this.down});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.length < 2) return;
    final peak = history.fold<int>(1, (top, e) => math.max(top, math.max(e.up, e.down)));
    void draw(int Function(TrafficSample) value, Color color) {
      final step = size.width / (_slots - 1);
      final start = size.width - step * (history.length - 1);
      final line = Path();
      for (final (index, sample) in history.indexed) {
        final x = start + step * index;
        final y = size.height - size.height * value(sample) / peak * 0.92;
        index == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
      }
      final area = Path.from(line)
        ..lineTo(size.width, size.height)
        ..lineTo(start, size.height)
        ..close();
      canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.12));
      canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.round,
      );
    }

    draw((e) => e.down, down);
    draw((e) => e.up, up);
  }

  @override
  bool shouldRepaint(_SpeedPainter old) => true;
}

class _Tile extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _Tile(this.label, this.value, {this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Palette.of(context).panel,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          // 总流量占两行，其余一行，高度要一样才排得齐
          constraints: const BoxConstraints(minHeight: 82, minWidth: double.infinity),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              Text(value, style: theme.textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 编辑首页：开关、数字和入口各放哪些，拖动调整顺序
class HomeStatsPage extends StatelessWidget {
  const HomeStatsPage({super.key});

  static const Map<String, String> _switchLabels = {
    HomeSwitch.capture: 'HTTPS 解密',
    HomeSwitch.systemProxy: '系统代理',
    HomeSwitch.tun: 'TUN 模式',
    HomeSwitch.rules: '分流',
    HomeSwitch.proxyBypass: '允许绕过系统代理',
    HomeSwitch.routeExclude: 'TUN 排除路由',
  };

  static const Map<String, String> _statLabels = {
    HomeStat.runtime: '运行时长',
    HomeStat.connections: '连接数',
    HomeStat.traffic: '总流量',
    HomeStat.speed: '速度',
    HomeStat.memory: '内存',
    HomeStat.outboundIp: '出口 IP',
  };

  static const Map<String, String> _shortcutLabels = {
    HomeShortcut.addProfile: '添加配置',
    HomeShortcut.profiles: '我的配置',
    HomeShortcut.connections: '连接',
    HomeShortcut.networkCheck: '网络检测',
    HomeShortcut.speedTest: '测速',
    HomeShortcut.ruleCheck: '规则检测',
    HomeShortcut.logs: '日志',
    HomeShortcut.statistics: '统计',
    HomeShortcut.dns: 'DNS',
    HomeShortcut.backup: '备份',
  };

  /// iOS 始终走 TUN，也没有系统代理
  static const Set<String> _windowsOnly = {
    HomeSwitch.systemProxy,
    HomeSwitch.tun,
    HomeSwitch.proxyBypass,
    HomeSwitch.routeExclude,
  };

  @override
  Widget build(BuildContext context) {
    final manager = CoreManager.instance;
    final settings = manager.settings;
    return AppPage(title: '编辑首页', children: [
      _HomeSection(
        title: '开关',
        items: {
          for (final entry in _switchLabels.entries)
            if (Platform.isWindows || !_windowsOnly.contains(entry.key)) entry.key: entry.value,
        },
        chosen: settings.homeSwitches,
        onChanged: (value) {
          settings.homeSwitches = value;
          manager.saveHomeLayout();
        },
      ),
      _HomeSection(
        title: '数字',
        hint: '连接后显示。选得越多，刷新越频繁',
        items: _statLabels,
        chosen: settings.homeStats,
        onChanged: manager.saveHomeStats,
      ),
      _HomeSection(
        title: '入口',
        items: _shortcutLabels,
        chosen: settings.homeShortcuts,
        onChanged: (value) {
          settings.homeShortcuts = value;
          manager.saveHomeLayout();
        },
      ),
    ]);
  }
}

class _HomeSection extends StatefulWidget {
  final String title;
  final String? hint;
  final Map<String, String> items;
  final List<String> chosen;
  final ValueChanged<List<String>> onChanged;

  const _HomeSection({required this.title, this.hint, required this.items, required this.chosen, required this.onChanged});

  @override
  State<_HomeSection> createState() => _HomeSectionState();
}

class _HomeSectionState extends State<_HomeSection> {
  late final Set<String> _chosen = widget.chosen.toSet();

  /// 选中的在前，按用户排的顺序；没选的跟在后面
  late final List<String> _order = [
    ...widget.chosen.where(widget.items.containsKey),
    ...widget.items.keys.where((e) => !widget.chosen.contains(e)),
  ];

  void _save() => widget.onChanged(_order.where(_chosen.contains).toList());

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(widget.title, hint: widget.hint),
      Material(
        color: Palette.of(context).panel,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        clipBehavior: Clip.antiAlias,
        child: ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _order.length,
          onReorder: (oldIndex, newIndex) {
            setState(() => _order.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, _order.removeAt(oldIndex)));
            _save();
          },
          itemBuilder: (context, index) {
            final item = _order[index];
            return CheckboxListTile(
              key: ValueKey(item),
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(widget.items[item]!),
              value: _chosen.contains(item),
              onChanged: (value) {
                setState(() => value == true ? _chosen.add(item) : _chosen.remove(item));
                _save();
              },
            );
          },
        ),
      ),
    ]);
  }
}
