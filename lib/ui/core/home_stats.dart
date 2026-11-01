import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/core/clash_api.dart';
import 'package:proxypin/core/connection_log.dart';
import 'package:proxypin/core/core_manager.dart';
import 'package:proxypin/core/core_settings.dart';
import 'package:proxypin/core/core_tools.dart';
import 'package:proxypin/network/bin/configuration.dart';

import 'connections_page.dart';
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
        if (mounted) setState(() => _sample = sample);
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
      HomeStat.speed => _Tile('速度', '↑ ${formatBytes(_sample.up)}/s\n↓ ${formatBytes(_sample.down)}/s'),
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
    if (tiles.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final width = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final tile in tiles) SizedBox(width: width, child: tile)],
        );
      },
    );
  }
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
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(value, style: theme.textTheme.bodyMedium),
          ]),
        ),
      ),
    );
  }
}

/// 选首页显示哪些数字，拖动调整顺序
class HomeStatsPage extends StatefulWidget {
  const HomeStatsPage({super.key});

  @override
  State<HomeStatsPage> createState() => _HomeStatsPageState();
}

class _HomeStatsPageState extends State<HomeStatsPage> {
  static const Map<String, String> _labels = {
    HomeStat.runtime: '运行时长',
    HomeStat.connections: '连接数',
    HomeStat.traffic: '总流量',
    HomeStat.speed: '速度',
    HomeStat.memory: '内存',
    HomeStat.outboundIp: '出口 IP',
  };

  final CoreManager _manager = CoreManager.instance;

  /// 选中的在前，按用户排的顺序；没选的跟在后面
  late final List<String> _order = [
    ..._manager.settings.homeStats,
    ...HomeStat.all.where((e) => !_manager.settings.homeStats.contains(e)),
  ];

  void _save() => _manager.saveHomeStats(_order.where(_manager.settings.homeStats.contains).toList());

  @override
  Widget build(BuildContext context) {
    final settings = _manager.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('首页显示')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('连接后显示在首页底部。选得越多，刷新越频繁。长按拖动调整顺序。', style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: ReorderableListView.builder(
            itemCount: _order.length,
            onReorder: (oldIndex, newIndex) {
              setState(() => _order.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, _order.removeAt(oldIndex)));
              _save();
            },
            itemBuilder: (context, index) {
              final stat = _order[index];
              return CheckboxListTile(
                key: ValueKey(stat),
                title: Text(_labels[stat]!),
                value: settings.homeStats.contains(stat),
                onChanged: (value) {
                  setState(() {
                    settings.homeStats = value == true ? [...settings.homeStats, stat] : (settings.homeStats.where((e) => e != stat).toList());
                  });
                  _save();
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
