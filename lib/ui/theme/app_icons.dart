import 'package:flutter/material.dart';

/// Every icon of the app, by what it means. Screens never name an icon font
/// directly, so the whole set changes in one place.
class AppIcons {
  AppIcons._();

  // Playback
  static const IconData play = Icons.play_arrow_rounded;
  static const IconData pause = Icons.pause_rounded;
  static const IconData next = Icons.skip_next_rounded;
  static const IconData previous = Icons.skip_previous_rounded;
  static const IconData shuffle = Icons.shuffle_rounded;
  static const IconData repeat = Icons.repeat_rounded;
  static const IconData repeatOne = Icons.repeat_one_rounded;
  static const IconData queue = Icons.queue_music_rounded;
  static const IconData addToQueue = Icons.playlist_add_rounded;
  static const IconData playNext = Icons.playlist_play_rounded;
  static const IconData lyrics = Icons.lyrics_outlined;
  static const IconData equalizer = Icons.equalizer_rounded;
  static const IconData speed = Icons.speed_rounded;
  static const IconData sleepTimer = Icons.bedtime_rounded;
  static const IconData sources = Icons.tune_rounded;
  static const IconData smart = Icons.auto_awesome_rounded;
  static const IconData canvas = Icons.slow_motion_video_rounded;
  static const IconData cover = Icons.image_outlined;
  static const IconData radio = Icons.sensors_rounded;

  // Library
  static const IconData heart = Icons.favorite_border_rounded;
  static const IconData heartFilled = Icons.favorite_rounded;
  static const IconData download = Icons.arrow_circle_down_outlined;
  static const IconData downloaded = Icons.arrow_circle_down_rounded;
  static const IconData save = Icons.add_circle_outline_rounded;
  static const IconData saved = Icons.check_circle_rounded;
  static const IconData note = Icons.music_note_rounded;
  static const IconData album = Icons.album_outlined;
  static const IconData playlist = Icons.library_music_outlined;
  static const IconData artist = Icons.person_rounded;
  static const IconData artistPage = Icons.person_outline_rounded;
  static const IconData artistMissing = Icons.person_off_outlined;
  static const IconData history = Icons.history_rounded;
  static const IconData verified = Icons.verified_rounded;

  // Navigation and actions
  static const IconData back = Icons.arrow_back_ios_new_rounded;
  static const IconData collapse = Icons.keyboard_arrow_down_rounded;
  static const IconData chevronRight = Icons.chevron_right_rounded;
  static const IconData more = Icons.more_horiz_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData search = Icons.search_rounded;
  static const IconData clear = Icons.cancel_rounded;
  static const IconData add = Icons.add_rounded;
  static const IconData check = Icons.check_rounded;
  static const IconData radioOn = Icons.radio_button_checked_rounded;
  static const IconData radioOff = Icons.radio_button_unchecked_rounded;
  static const IconData trash = Icons.delete_outline_rounded;
  static const IconData sort = Icons.swap_vert_rounded;
  static const IconData grid = Icons.grid_view_rounded;
  static const IconData list = Icons.format_list_bulleted_rounded;
  static const IconData dragHandle = Icons.drag_handle_rounded;
  static const IconData link = Icons.link_rounded;
  static const IconData paste = Icons.content_paste_rounded;
  static const IconData copy = Icons.copy_rounded;
  static const IconData refresh = Icons.refresh_rounded;
  static const IconData settings = Icons.settings_outlined;
  static const IconData log = Icons.description_outlined;
  static const IconData offline = Icons.wifi_off_rounded;
  static const IconData account = Icons.account_circle_outlined;
  static const IconData import = Icons.download_rounded;
  static const IconData time = Icons.schedule_rounded;
}

/// The three glyphs of the tab bar, drawn by hand: thin outlines at rest,
/// solid and heavier when their tab is the current one.
enum NavGlyph { home, search, library }

class NavGlyphIcon extends StatelessWidget {
  const NavGlyphIcon({
    super.key,
    required this.glyph,
    required this.active,
    required this.color,
    this.size = 26,
  });

  final NavGlyph glyph;
  final bool active;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _NavGlyphPainter(glyph, active, color),
      );
}

class _NavGlyphPainter extends CustomPainter {
  const _NavGlyphPainter(this.glyph, this.active, this.color);

  final NavGlyph glyph;
  final bool active;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Every glyph is designed on a 24 × 24 grid.
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 2.6 : 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (glyph) {
      case NavGlyph.home:
        // A house whose door is a notch in the outline.
        final house = Path()
          ..moveTo(12, 3.6)
          ..lineTo(20.4, 10.2)
          ..lineTo(20.4, 20.4)
          ..lineTo(14.6, 20.4)
          ..lineTo(14.6, 14.4)
          ..lineTo(9.4, 14.4)
          ..lineTo(9.4, 20.4)
          ..lineTo(3.6, 20.4)
          ..lineTo(3.6, 10.2)
          ..close();
        if (active) {
          canvas.drawPath(house, Paint()..color = color);
          canvas.drawPath(house, stroke..strokeWidth = 1.9);
        } else {
          canvas.drawPath(house, stroke);
        }
      case NavGlyph.search:
        canvas.drawCircle(const Offset(10.7, 10.7), 6.6, stroke);
        canvas.drawLine(const Offset(15.7, 15.7), const Offset(20.4, 20.4), stroke);
      case NavGlyph.library:
        // Two records standing upright and one leaning on them.
        canvas.drawLine(const Offset(4.6, 3.8), const Offset(4.6, 20.2), stroke);
        canvas.drawLine(const Offset(10.2, 3.8), const Offset(10.2, 20.2), stroke);
        canvas.drawLine(const Offset(15.2, 4.6), const Offset(19.6, 20.2), stroke);
    }
  }

  @override
  bool shouldRepaint(_NavGlyphPainter old) =>
      old.glyph != glyph || old.active != active || old.color != color;
}
