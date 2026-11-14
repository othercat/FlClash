import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/donut_chart.dart';
import 'package:fl_clash/widgets/line_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('DonutChart animates for 300ms after every data update', (
    tester,
  ) async {
    final value = ValueNotifier<double>(1);
    addTearDown(value.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) {
          globalState.theme = CommonTheme.of(context, 1);
          return child!;
        },
        home: SizedBox.square(
          dimension: 120,
          child: ValueListenableBuilder<double>(
            valueListenable: value,
            builder: (_, current, _) => DonutChart(
              data: [
                DonutChartData(value: current, color: Colors.blue),
                const DonutChartData(value: 1, color: Colors.red),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.hasRunningAnimations, isFalse);
    for (var second = 0; second < 3; second++) {
      value.value += 1;
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);

      await tester.pump(const Duration(milliseconds: 299));
      expect(tester.hasRunningAnimations, isTrue);

      await tester.pump(const Duration(milliseconds: 2));
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pump(const Duration(milliseconds: 699));
      expect(tester.hasRunningAnimations, isFalse);
    }
  });

  testWidgets('LineChart default zero duration does not keep a ticker active', (
    tester,
  ) async {
    final value = ValueNotifier<double>(1);
    addTearDown(value.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) {
          globalState.theme = CommonTheme.of(context, 1);
          return child!;
        },
        home: SizedBox(
          width: 200,
          height: 120,
          child: ValueListenableBuilder<double>(
            valueListenable: value,
            builder: (_, current, _) => LineChart(
              color: Colors.blue,
              points: [const Point(0, 0), Point(1, current)],
            ),
          ),
        ),
      ),
    );

    value.value += 1;
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('DonutChart restarts for a recreated equal data list', (
    tester,
  ) async {
    final rebuild = ValueNotifier<int>(0);
    addTearDown(rebuild.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) {
          globalState.theme = CommonTheme.of(context, 1);
          return child!;
        },
        home: SizedBox.square(
          dimension: 120,
          child: ValueListenableBuilder<int>(
            valueListenable: rebuild,
            builder: (_, _, _) => DonutChart(
              data: [
                const DonutChartData(value: 1, color: Colors.blue),
                const DonutChartData(value: 1, color: Colors.red),
              ],
            ),
          ),
        ),
      ),
    );

    rebuild.value += 1;
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(const Duration(milliseconds: 301));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('DonutChart zero duration does not retain a ticker', (
    tester,
  ) async {
    final value = ValueNotifier<double>(1);
    addTearDown(value.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) {
          globalState.theme = CommonTheme.of(context, 1);
          return child!;
        },
        home: SizedBox.square(
          dimension: 120,
          child: ValueListenableBuilder<double>(
            valueListenable: value,
            builder: (_, current, _) => DonutChart(
              duration: Duration.zero,
              data: [
                DonutChartData(value: current, color: Colors.blue),
                const DonutChartData(value: 1, color: Colors.red),
              ],
            ),
          ),
        ),
      ),
    );

    for (var second = 0; second < 3; second++) {
      value.value += 1;
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.hasRunningAnimations, isFalse);
    }
  });
}
