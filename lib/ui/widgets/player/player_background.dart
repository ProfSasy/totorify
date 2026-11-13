import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../theme/app_ambience.dart';
import '../app_cover.dart';

/// The cover of the song, blurred and darkened, behind the whole player.
class BlurredCover extends StatelessWidget {
  const BlurredCover({super.key, required this.url, required this.palette});

  final String url;
  final AmbientPalette palette;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: palette.deep),
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 38, sigmaY: 38),
          child: Image(image: imageProviderFor(url), fit: BoxFit.cover),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.35),
                Colors.black.withValues(alpha: 0.5),
                Colors.black.withValues(alpha: 0.85),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
