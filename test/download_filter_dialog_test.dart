import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/pages/download/widget/download_filter_dialog.dart';

void main() {
  testWidgets('tag suggestions match the field width and stay centered',
      (WidgetTester tester) async {
    const Key fieldKey = ValueKey<String>('tag-field');
    final LayerLink layerLink = LayerLink();

    await tester.pumpWidget(
      MaterialApp(
        home: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (_) => Center(
                child: CompositedTransformTarget(
                  key: fieldKey,
                  link: layerLink,
                  child: const SizedBox(width: 360, height: 40),
                ),
              ),
            ),
            OverlayEntry(
              builder: (_) => buildDownloadTagSuggestionPopup(
                layerLink: layerLink,
                width: 360,
                child: const SizedBox(height: 100),
              ),
            ),
          ],
        ),
      ),
    );

    final Rect fieldRect = tester.getRect(find.byKey(fieldKey));
    final Finder popup =
        find.byKey(const ValueKey<String>('download-tag-suggestion-popup'));
    expect(popup, findsOneWidget);

    final Rect popupRect = tester.getRect(popup);
    expect(popupRect.width, closeTo(fieldRect.width, 0.01));
    expect(popupRect.center.dx, closeTo(fieldRect.center.dx, 0.01));
    expect(popupRect.top, closeTo(fieldRect.bottom + 4, 0.01));
  });
}
