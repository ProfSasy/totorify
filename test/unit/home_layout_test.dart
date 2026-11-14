import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/ui/home_layout.dart';

void main() {
  const all = HomeLayout.defaultOrder;

  test('with nothing chosen the Home is as designed', () {
    expect(HomeLayout.order(const []), all);
    expect(HomeLayout.visible(const [], const []), all);
  });

  test('every section has a name for the settings', () {
    expect(HomeLayout.labels.keys.toSet(), all.toSet());
    expect(all.toSet(), hasLength(all.length));
  });

  test('the order chosen is kept', () {
    final chosen = all.reversed.toList();
    expect(HomeLayout.order(chosen), chosen);
  });

  test('sections the saved order does not name go where the design put them', () {
    // Saved by a version that knew only these three, moved around.
    final saved = [HomeLayout.charts, HomeLayout.recent, HomeLayout.quick];
    final order = HomeLayout.order(saved);

    expect(order.toSet(), all.toSet());
    expect(order, hasLength(all.length));
    // The three keep the order chosen.
    expect(order.where(saved.contains), saved);
    // The last section of the design, unknown to the saved order, is last.
    expect(order.last, HomeLayout.listenNow);
  });

  test('a section added between two known ones lands before the later one', () {
    final saved = [for (final id in all) if (id != HomeLayout.mixes) id];
    final order = HomeLayout.order(saved);
    expect(order, all);
  });

  test('names that are not sections, and repeats, are dropped', () {
    final order = HomeLayout.order(['nope', HomeLayout.recent, HomeLayout.recent, '']);
    expect(order.where((id) => id == HomeLayout.recent), hasLength(1));
    expect(order, isNot(contains('nope')));
    // One known section alone moves nothing: the rest goes around it.
    expect(order, all);
  });

  test('hidden sections are left out, the others keep their order', () {
    final visible = HomeLayout.visible(
      [HomeLayout.playlists, for (final id in all) if (id != HomeLayout.playlists) id],
      [HomeLayout.charts, HomeLayout.quick, 'nope'],
    );
    expect(visible, isNot(contains(HomeLayout.charts)));
    expect(visible, isNot(contains(HomeLayout.quick)));
    expect(visible.first, HomeLayout.playlists);
    expect(visible, hasLength(all.length - 2));
  });

  test('everything can be hidden', () {
    expect(HomeLayout.visible(const [], all), isEmpty);
  });
}
