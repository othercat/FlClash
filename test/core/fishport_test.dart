import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/fishport.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/views/proxies/card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockProcess extends Mock implements Process {}

class _MockStdin extends Mock implements IOSink {}

class _Helper {
  final output = StreamController<List<int>>(sync: true);
  final exited = Completer<int>();
  int starts = 0;

  Future<Process> launch(String executable, List<String> args) async {
    starts++;
    final process = _MockProcess();
    final input = _MockStdin();
    when(() => input.close()).thenAnswer((_) async {
      await output.close();
      exited.complete(0);
    });
    when(() => process.stdin).thenReturn(input);
    when(() => process.stdout).thenAnswer((_) => output.stream);
    when(() => process.stderr).thenAnswer((_) => const Stream.empty());
    when(() => process.exitCode).thenAnswer((_) => exited.future);
    emit({'port': 32345, 'fingerprint': 'a' * 64, 'password': 'b' * 40});
    return process;
  }

  void emit(Map<String, dynamic> event) =>
      output.add(utf8.encode('${jsonEncode(event)}\n'));

  void state(String state) =>
      emit({'state': state, 'nodes': state == 'ready' ? 24 : 0});
}

const _profile =
    '{"proxies":[{"type":"direct","name":"existing"},'
    '{"type":"socks5","name":"custom HK","username":"香港1","x-fishport-protocol":"phantom"},'
    '{"type":"socks5","name":"custom JP","username":"日本1","x-fishport-protocol":"phantom"}]}';

void main() {
  test(
    'binds markers once and scopes live credential errors to profile and node',
    () async {
      final helper = _Helper();
      final service = DesktopFishport(startProcess: helper.launch);
      addTearDown(service.close);
      final profile = jsonDecode(_profile) as Map<String, dynamic>;
      final other = jsonDecode(_profile) as Map<String, dynamic>;
      await Future.wait([
        service.configure(profile, 'fixture', profileId: 7),
        service.configure(other, 'fixture', profileId: 8),
      ]);
      final nodes = profile['proxies'] as List<dynamic>;
      expect(helper.starts, 1);
      expect(nodes.first, {'type': 'direct', 'name': 'existing'});
      expect(nodes.skip(1).map((p) => p['username']), ['香港1', '日本1']);
      for (final node in nodes.skip(1)) {
        expect(node['port'], 32345);
        expect(node['password'], 'b' * 40);
        expect(node.containsKey('x-fishport-protocol'), isFalse);
      }
      expect(other, profile);
      helper.state('account-file-missing');
      expect(service.problemFor(7, 'custom HK'), FishportProblem.missing);
      expect(service.problemFor(8, 'custom JP'), FishportProblem.missing);
      expect(service.problemFor(7, 'existing'), isNull);
      expect(service.problemFor(9, 'custom HK'), isNull);
      await service.configure({'proxies': []}, 'fixture', profileId: 7);
      helper.state('account-rejected');
      expect(service.problemFor(7, 'custom HK'), isNull);
      expect(service.problemFor(8, 'custom JP'), FishportProblem.rejected);
      helper.state('ready');
      expect(service.problemFor(8, 'custom JP'), isNull);
    },
  );

  testWidgets(
    'node labels and file instructions update without reloading the profile',
    (tester) async {
      final helper = _Helper();
      final service = DesktopFishport(startProcess: helper.launch);
      addTearDown(service.close);
      await service.configure(jsonDecode(_profile), 'fixture', profileId: 7);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: Material(
            child: Column(
              children: [
                FishportNodeStatus(
                  service: service,
                  profileId: 7,
                  name: 'custom HK',
                  child: const Text('35 ms'),
                ),
                FishportNodeStatus(
                  service: service,
                  profileId: 7,
                  name: 'existing',
                  child: const Text('12 ms'),
                ),
              ],
            ),
          ),
        ),
      );
      helper.state('account-file-missing');
      await tester.pumpAndSettle();
      expect(find.text('缺少账号文件'), findsOneWidget);
      expect(find.byTooltip(RegExp('fishport-pass.txt')), findsOneWidget);
      await tester.tap(find.text('缺少账号文件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('第一行填写账号'), findsOneWidget);
      Tooltip.dismissAllToolTips();
      await tester.pumpAndSettle();
      for (final entry in {
        'account-file-format': '账号文件格式错误',
        'account-file-unreadable': '无法读取账号文件',
        'account-rejected': '账号或密码错误',
        'network-unavailable': 'Fishport 暂时不可用',
        'rate-limited': '登录过于频繁，稍后重试',
      }.entries) {
        helper.state(entry.key);
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget);
        expect(find.text('12 ms'), findsOneWidget);
        expect(find.text('35 ms'), findsNothing);
      }
      helper.state('ready');
      await tester.pumpAndSettle();
      expect(find.text('35 ms'), findsOneWidget);
      expect(find.text('12 ms'), findsOneWidget);
    },
  );
}
