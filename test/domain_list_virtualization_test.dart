import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/multi_select_controller.dart';
import 'package:proxypin/ui/component/transition.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/desktop/request/domains.dart';
import 'package:proxypin/ui/desktop/request/request.dart';
import 'package:proxypin/utils/listenable_list.dart';

HttpRequest _request(String host, int index) {
  return HttpRequest(HttpMethod.get, '/resource/$index', protocolVersion: 'HTTP/1.1')
    ..hostAndPort = HostAndPort.host(host, 443, scheme: HostAndPort.httpsScheme)
    ..headers.host = host;
}

ListenableList<HttpRequest> _requests(Map<String, int> counts) {
  return ListenableList([
    for (final entry in counts.entries)
      for (var i = 0; i < entry.value; i++) _request(entry.key, i)
  ]);
}

Future<void> _pumpList(WidgetTester tester, ListenableList<HttpRequest> list) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: DomainList(
        list: list,
        panel: NetworkTabController(tabStyle: const TextStyle(), proxyServer: ProxyServer(Configuration.fromJson({}))),
        proxyServer: ProxyServer(Configuration.fromJson({})),
        selectionController: MultiSelectController(),
        selectionHandlers: RequestSelectionHandlers(
          onRangeSelection: (_) {},
          onDeleteSelected: () {},
          onRepeatSelected: () {},
          onExportSelected: () async {},
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  const domain = 'many.example.test';

  testWidgets('an expanded domain only builds the rows on screen', (tester) async {
    await _pumpList(tester, _requests({domain: 3000}));
    expect(find.byType(RequestWidget, skipOffstage: false), findsNothing, reason: 'collapsed by default');

    await tester.tap(find.textContaining(domain));
    await tester.pump();

    final built = find.byType(RequestWidget, skipOffstage: false).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(100), reason: 'rows are built lazily, not all 3000 at once');
  });

  testWidgets('rows further down are reachable by scrolling', (tester) async {
    await _pumpList(tester, _requests({domain: 3000}));
    await tester.tap(find.textContaining(domain));
    await tester.pump();

    expect(find.textContaining('#2999 '), findsOneWidget, reason: 'newest first');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -200000));
    await tester.pumpAndSettle();
    expect(find.textContaining('#0 '), findsOneWidget);
    expect(find.textContaining('#2999 '), findsNothing);
  });

  testWidgets('domains stack in order and collapse independently', (tester) async {
    await _pumpList(tester, _requests({'a.example.test': 3, 'b.example.test': 2}));
    final a = find.textContaining('a.example.test'), b = find.textContaining('b.example.test');

    expect(tester.getTopLeft(a).dy, lessThan(tester.getTopLeft(b).dy));

    final collapsedGap = tester.getTopLeft(b).dy - tester.getTopLeft(a).dy;
    await tester.tap(a);
    await tester.pump();
    expect(find.byType(RequestWidget), findsNWidgets(3));
    expect(tester.getTopLeft(b).dy - tester.getTopLeft(a).dy, greaterThan(collapsedGap), reason: 'rows push b down');

    await tester.tap(b);
    await tester.pump();
    expect(find.byType(RequestWidget), findsNWidgets(5));

    await tester.tap(a);
    await tester.pump();
    expect(find.byType(RequestWidget), findsNWidgets(2));
  });

  testWidgets('a response set while a row is scrolled away shows when it returns', (tester) async {
    await _pumpList(tester, _requests({domain: 500}));
    await tester.tap(find.textContaining(domain));
    await tester.pump();

    final state = tester.state<DomainWidgetState>(find.byType(DomainList));
    final requests = state.containerMap.values.single;
    final first = requests.body.first;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -30000));
    await tester.pumpAndSettle();
    expect(find.byWidget(first), findsNothing);

    first.setResponse(HttpResponse(HttpStatus(418, "I'm a teapot"))..request = first.request);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 60000));
    await tester.pumpAndSettle();
    expect(find.textContaining('[418]'), findsOneWidget);
  });

  testWidgets('the header highlight still animates in its new sliver parent', (tester) async {
    await _pumpList(tester, _requests({domain: 2}));
    expect(find.byType(ColorTransition), findsOneWidget);
    expect(find.byType(SliverMainAxisGroup), findsOneWidget);
  });
}
