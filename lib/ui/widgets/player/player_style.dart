import 'package:flutter/material.dart';

/// The colors of the player that do not come from the cover. The player is
/// dark with white text, whatever the cover, unless the user wants it in
/// the colors of the theme: `PlayerSheet` sets these before it draws.
class PlayerStyle {
  PlayerStyle._();

  /// The color of text and icons.
  static Color ink = Colors.white;

  /// What darkens a picture or a video under the text: black, or the
  /// background of the theme when the player is drawn in its colors.
  static Color shade = Colors.black;

  /// Back to the dark player.
  static void dark() {
    ink = Colors.white;
    shade = Colors.black;
  }
}

/// The color of text and icons in the player.
Color get playerInk => PlayerStyle.ink;

/// How long the cover and the Canvas take to give way to each other.
const Duration playerCanvasFade = Duration(milliseconds: 380);
