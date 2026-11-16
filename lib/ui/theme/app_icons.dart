import 'package:flutter/material.dart';

import '../../services/app_settings.dart';

/// Every icon of the app, by what it means. Screens never name an icon font
/// directly, so the whole set changes in one place.
class AppIcons {
  AppIcons._();

  /// What the sets are called in the settings, by `AppSettings.iconStyle`.
  static const List<String> styleLabels = ['Predefinite', 'Arrotondate', 'Squadrate', 'Contorno'];

  /// The icon of the set the user chose: the designed one, or its rounded,
  /// sharp or outlined drawing.
  static IconData _pick(IconData designed, IconData rounded, IconData sharp, IconData outlined) =>
      switch (AppSettings.instance.iconStyle.value) {
        1 => rounded,
        2 => sharp,
        3 => outlined,
        _ => designed,
      };

  // Playback
  static IconData get play =>
      _pick(Icons.play_arrow_rounded, Icons.play_arrow_rounded, Icons.play_arrow_sharp, Icons.play_arrow_outlined);
  static IconData get pause =>
      _pick(Icons.pause_rounded, Icons.pause_rounded, Icons.pause_sharp, Icons.pause_outlined);
  static IconData get next =>
      _pick(Icons.skip_next_rounded, Icons.skip_next_rounded, Icons.skip_next_sharp, Icons.skip_next_outlined);
  static IconData get previous =>
      _pick(Icons.skip_previous_rounded, Icons.skip_previous_rounded, Icons.skip_previous_sharp, Icons.skip_previous_outlined);
  static IconData get shuffle =>
      _pick(Icons.shuffle_rounded, Icons.shuffle_rounded, Icons.shuffle_sharp, Icons.shuffle_outlined);
  static IconData get repeat =>
      _pick(Icons.repeat_rounded, Icons.repeat_rounded, Icons.repeat_sharp, Icons.repeat_outlined);
  static IconData get repeatOne =>
      _pick(Icons.repeat_one_rounded, Icons.repeat_one_rounded, Icons.repeat_one_sharp, Icons.repeat_one_outlined);
  static IconData get queue =>
      _pick(Icons.queue_music_rounded, Icons.queue_music_rounded, Icons.queue_music_sharp, Icons.queue_music_outlined);
  static IconData get addToQueue =>
      _pick(Icons.playlist_add_rounded, Icons.playlist_add_rounded, Icons.playlist_add_sharp, Icons.playlist_add_outlined);
  static IconData get playNext =>
      _pick(Icons.playlist_play_rounded, Icons.playlist_play_rounded, Icons.playlist_play_sharp, Icons.playlist_play_outlined);
  static IconData get lyrics =>
      _pick(Icons.lyrics_outlined, Icons.lyrics_rounded, Icons.lyrics_sharp, Icons.lyrics_outlined);
  static IconData get equalizer =>
      _pick(Icons.equalizer_rounded, Icons.equalizer_rounded, Icons.equalizer_sharp, Icons.equalizer_outlined);
  static IconData get speed =>
      _pick(Icons.speed_rounded, Icons.speed_rounded, Icons.speed_sharp, Icons.speed_outlined);
  static IconData get sleepTimer =>
      _pick(Icons.bedtime_rounded, Icons.bedtime_rounded, Icons.bedtime_sharp, Icons.bedtime_outlined);
  static IconData get sources =>
      _pick(Icons.tune_rounded, Icons.tune_rounded, Icons.tune_sharp, Icons.tune_outlined);
  static IconData get smart =>
      _pick(Icons.auto_awesome_rounded, Icons.auto_awesome_rounded, Icons.auto_awesome_sharp, Icons.auto_awesome_outlined);
  static IconData get canvas =>
      _pick(Icons.slow_motion_video_rounded, Icons.slow_motion_video_rounded, Icons.slow_motion_video_sharp, Icons.slow_motion_video_outlined);
  static IconData get cover =>
      _pick(Icons.image_outlined, Icons.image_rounded, Icons.image_sharp, Icons.image_outlined);
  static IconData get radio =>
      _pick(Icons.sensors_rounded, Icons.sensors_rounded, Icons.sensors_sharp, Icons.sensors_outlined);

  // Library
  static IconData get heart =>
      _pick(Icons.favorite_border_rounded, Icons.favorite_border_rounded, Icons.favorite_border_sharp, Icons.favorite_border_outlined);
  static IconData get heartFilled =>
      _pick(Icons.favorite_rounded, Icons.favorite_rounded, Icons.favorite_sharp, Icons.favorite_outlined);
  static IconData get download =>
      _pick(Icons.arrow_circle_down_outlined, Icons.arrow_circle_down_rounded, Icons.arrow_circle_down_sharp, Icons.arrow_circle_down_outlined);
  static IconData get downloaded =>
      _pick(Icons.arrow_circle_down_rounded, Icons.arrow_circle_down_rounded, Icons.arrow_circle_down_sharp, Icons.arrow_circle_down_outlined);
  static IconData get save =>
      _pick(Icons.add_circle_outline_rounded, Icons.add_circle_outline_rounded, Icons.add_circle_outline_sharp, Icons.add_circle_outline_outlined);
  static IconData get saved =>
      _pick(Icons.check_circle_rounded, Icons.check_circle_rounded, Icons.check_circle_sharp, Icons.check_circle_outlined);
  static IconData get note =>
      _pick(Icons.music_note_rounded, Icons.music_note_rounded, Icons.music_note_sharp, Icons.music_note_outlined);
  static IconData get album =>
      _pick(Icons.album_outlined, Icons.album_rounded, Icons.album_sharp, Icons.album_outlined);
  static IconData get playlist =>
      _pick(Icons.library_music_outlined, Icons.library_music_rounded, Icons.library_music_sharp, Icons.library_music_outlined);
  static IconData get artist =>
      _pick(Icons.person_rounded, Icons.person_rounded, Icons.person_sharp, Icons.person_outlined);
  static IconData get artistPage =>
      _pick(Icons.person_outline_rounded, Icons.person_outline_rounded, Icons.person_outline_sharp, Icons.person_outline_outlined);
  static IconData get artistMissing =>
      _pick(Icons.person_off_outlined, Icons.person_off_rounded, Icons.person_off_sharp, Icons.person_off_outlined);
  static IconData get history =>
      _pick(Icons.history_rounded, Icons.history_rounded, Icons.history_sharp, Icons.history_outlined);
  static IconData get verified =>
      _pick(Icons.verified_rounded, Icons.verified_rounded, Icons.verified_sharp, Icons.verified_outlined);

  // Navigation and actions
  static IconData get back =>
      _pick(Icons.arrow_back_ios_new_rounded, Icons.arrow_back_ios_new_rounded, Icons.arrow_back_ios_new_sharp, Icons.arrow_back_ios_new_outlined);
  static IconData get collapse =>
      _pick(Icons.keyboard_arrow_down_rounded, Icons.keyboard_arrow_down_rounded, Icons.keyboard_arrow_down_sharp, Icons.keyboard_arrow_down_outlined);
  static IconData get chevronRight =>
      _pick(Icons.chevron_right_rounded, Icons.chevron_right_rounded, Icons.chevron_right_sharp, Icons.chevron_right_outlined);
  static IconData get more =>
      _pick(Icons.more_horiz_rounded, Icons.more_horiz_rounded, Icons.more_horiz_sharp, Icons.more_horiz_outlined);
  static IconData get close =>
      _pick(Icons.close_rounded, Icons.close_rounded, Icons.close_sharp, Icons.close_outlined);
  static IconData get search =>
      _pick(Icons.search_rounded, Icons.search_rounded, Icons.search_sharp, Icons.search_outlined);
  static IconData get clear =>
      _pick(Icons.cancel_rounded, Icons.cancel_rounded, Icons.cancel_sharp, Icons.cancel_outlined);
  static IconData get add =>
      _pick(Icons.add_rounded, Icons.add_rounded, Icons.add_sharp, Icons.add_outlined);
  static IconData get check =>
      _pick(Icons.check_rounded, Icons.check_rounded, Icons.check_sharp, Icons.check_outlined);
  static IconData get radioOn =>
      _pick(Icons.radio_button_checked_rounded, Icons.radio_button_checked_rounded, Icons.radio_button_checked_sharp, Icons.radio_button_checked_outlined);
  static IconData get radioOff =>
      _pick(Icons.radio_button_unchecked_rounded, Icons.radio_button_unchecked_rounded, Icons.radio_button_unchecked_sharp, Icons.radio_button_unchecked_outlined);
  static IconData get trash =>
      _pick(Icons.delete_outline_rounded, Icons.delete_outline_rounded, Icons.delete_outline_sharp, Icons.delete_outline_outlined);
  static IconData get sort =>
      _pick(Icons.swap_vert_rounded, Icons.swap_vert_rounded, Icons.swap_vert_sharp, Icons.swap_vert_outlined);
  static IconData get grid =>
      _pick(Icons.grid_view_rounded, Icons.grid_view_rounded, Icons.grid_view_sharp, Icons.grid_view_outlined);
  static IconData get list =>
      _pick(Icons.format_list_bulleted_rounded, Icons.format_list_bulleted_rounded, Icons.format_list_bulleted_sharp, Icons.format_list_bulleted_outlined);
  static IconData get dragHandle =>
      _pick(Icons.drag_handle_rounded, Icons.drag_handle_rounded, Icons.drag_handle_sharp, Icons.drag_handle_outlined);
  static IconData get link =>
      _pick(Icons.link_rounded, Icons.link_rounded, Icons.link_sharp, Icons.link_outlined);
  static IconData get paste =>
      _pick(Icons.content_paste_rounded, Icons.content_paste_rounded, Icons.content_paste_sharp, Icons.content_paste_outlined);
  static IconData get copy =>
      _pick(Icons.copy_rounded, Icons.copy_rounded, Icons.copy_sharp, Icons.copy_outlined);
  static IconData get refresh =>
      _pick(Icons.refresh_rounded, Icons.refresh_rounded, Icons.refresh_sharp, Icons.refresh_outlined);
  static IconData get settings =>
      _pick(Icons.settings_outlined, Icons.settings_rounded, Icons.settings_sharp, Icons.settings_outlined);
  static IconData get log =>
      _pick(Icons.description_outlined, Icons.description_rounded, Icons.description_sharp, Icons.description_outlined);
  static IconData get offline =>
      _pick(Icons.wifi_off_rounded, Icons.wifi_off_rounded, Icons.wifi_off_sharp, Icons.wifi_off_outlined);
  static IconData get account =>
      _pick(Icons.account_circle_outlined, Icons.account_circle_rounded, Icons.account_circle_sharp, Icons.account_circle_outlined);
  static IconData get import =>
      _pick(Icons.download_rounded, Icons.download_rounded, Icons.download_sharp, Icons.download_outlined);
  static IconData get time =>
      _pick(Icons.schedule_rounded, Icons.schedule_rounded, Icons.schedule_sharp, Icons.schedule_outlined);
  static IconData get info =>
      _pick(Icons.info_outline_rounded, Icons.info_outline_rounded, Icons.info_outline_sharp, Icons.info_outline_rounded);
  static IconData get share =>
      _pick(Icons.ios_share_rounded, Icons.ios_share_rounded, Icons.ios_share_sharp, Icons.ios_share_outlined);
  static IconData get privacy =>
      _pick(Icons.privacy_tip_outlined, Icons.privacy_tip_rounded, Icons.privacy_tip_sharp, Icons.privacy_tip_outlined);
  static IconData get playback =>
      _pick(Icons.graphic_eq_rounded, Icons.graphic_eq_rounded, Icons.graphic_eq_sharp, Icons.graphic_eq_outlined);
  static IconData get skip =>
      _pick(Icons.fast_forward_rounded, Icons.fast_forward_rounded, Icons.fast_forward_sharp, Icons.fast_forward_outlined);
  static IconData get stats =>
      _pick(Icons.insights_rounded, Icons.insights_rounded, Icons.insights_sharp, Icons.insights_outlined);
  static IconData get backup =>
      _pick(Icons.save_alt_rounded, Icons.save_alt_rounded, Icons.save_alt_sharp, Icons.save_alt_outlined);
  static IconData get translate =>
      _pick(Icons.translate_rounded, Icons.translate_rounded, Icons.translate_sharp, Icons.translate_outlined);
  static IconData get mic =>
      _pick(Icons.mic_none_rounded, Icons.mic_none_rounded, Icons.mic_none_sharp, Icons.mic_none_outlined);
  static IconData get edit =>
      _pick(Icons.edit_outlined, Icons.edit_rounded, Icons.edit_sharp, Icons.edit_outlined);
  static IconData get pin =>
      _pick(Icons.push_pin_outlined, Icons.push_pin_rounded, Icons.push_pin_sharp, Icons.push_pin_outlined);
  static IconData get pinned =>
      _pick(Icons.push_pin_rounded, Icons.push_pin_rounded, Icons.push_pin_sharp, Icons.push_pin_outlined);
  static IconData get hide =>
      _pick(Icons.visibility_off_outlined, Icons.visibility_off_rounded, Icons.visibility_off_sharp, Icons.visibility_off_outlined);
  static IconData get block =>
      _pick(Icons.block_rounded, Icons.block_rounded, Icons.block_sharp, Icons.block_outlined);
  static IconData get integrations =>
      _pick(Icons.extension_outlined, Icons.extension_rounded, Icons.extension_sharp, Icons.extension_outlined);
  static IconData get appearance =>
      _pick(Icons.palette_outlined, Icons.palette_rounded, Icons.palette_sharp, Icons.palette_outlined);
  static IconData get together =>
      _pick(Icons.groups_outlined, Icons.groups_rounded, Icons.groups_sharp, Icons.groups_outlined);
  static IconData get folder =>
      _pick(Icons.folder_open_rounded, Icons.folder_open_rounded, Icons.folder_open_sharp, Icons.folder_open_outlined);
  static IconData get select =>
      _pick(Icons.checklist_rounded, Icons.checklist_rounded, Icons.checklist_sharp, Icons.checklist_outlined);
  static IconData get image =>
      _pick(Icons.image_outlined, Icons.image_rounded, Icons.image_sharp, Icons.image_outlined);
  static IconData get timer =>
      _pick(Icons.timelapse_rounded, Icons.timelapse_rounded, Icons.timelapse_sharp, Icons.timelapse_outlined);
  static IconData get update =>
      _pick(Icons.system_update_alt_rounded, Icons.system_update_alt_rounded, Icons.system_update_alt_sharp, Icons.system_update_alt_outlined);

  // Devices
  static IconData get devices =>
      _pick(Icons.speaker_group_outlined, Icons.speaker_group_rounded, Icons.speaker_group_sharp, Icons.speaker_group_outlined);
  static IconData get tv =>
      _pick(Icons.tv_rounded, Icons.tv_rounded, Icons.tv_sharp, Icons.tv_outlined);
  static IconData get phone =>
      _pick(Icons.smartphone_rounded, Icons.smartphone_rounded, Icons.smartphone_sharp, Icons.smartphone_outlined);
  static IconData get computer =>
      _pick(Icons.computer_rounded, Icons.computer_rounded, Icons.computer_sharp, Icons.computer_outlined);
  static IconData get volumeDown =>
      _pick(Icons.volume_down_rounded, Icons.volume_down_rounded, Icons.volume_down_sharp, Icons.volume_down_outlined);
  static IconData get volumeUp =>
      _pick(Icons.volume_up_rounded, Icons.volume_up_rounded, Icons.volume_up_sharp, Icons.volume_up_outlined);
}

/// The three glyphs of the tab bar, drawn by hand: thin outlines at rest,
/// solid and heavier when their tab is the current one.
enum NavGlyph { home, search, library, create }

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
      case NavGlyph.create:
        canvas.drawLine(const Offset(12, 4.4), const Offset(12, 19.6), stroke);
        canvas.drawLine(const Offset(4.4, 12), const Offset(19.6, 12), stroke);
    }
  }

  @override
  bool shouldRepaint(_NavGlyphPainter old) =>
      old.glyph != glyph || old.active != active || old.color != color;
}
