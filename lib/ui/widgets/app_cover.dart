import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/storage_service.dart';

import '../theme/app_icons.dart';
import '../theme/app_tokens.dart';

/// The picture behind [url]: a file of the app for a `local:` image, the
/// network (through the cache) otherwise.
ImageProvider imageProviderFor(String url) {
  final local = StorageService.instance.localImagePath(url);
  return local != null ? FileImage(File(local)) : CachedNetworkImageProvider(url);
}

/// Square (or round) artwork with one placeholder for every way it can be
/// missing: no URL, still loading, failed.
class AppCover extends StatelessWidget {
  const AppCover({
    super.key,
    required this.url,
    required this.size,
    this.radius = AppRadius.xs,
    this.circle = false,
    this.icon = AppIcons.note,
  });

  final String? url;
  final double size;
  final double radius;
  final bool circle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.42, color: cs.onSurfaceVariant),
    );
    final url = this.url;
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();

    final local = StorageService.instance.localImagePath(url);
    final image = (url == null || url.isEmpty)
        ? placeholder
        : local != null
        ? Image.file(
            File(local),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: pixels,
            errorBuilder: (_, _, _) => placeholder,
          )
        : CachedNetworkImage(
            imageUrl: url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            memCacheWidth: pixels,
            fadeInDuration: const Duration(milliseconds: 160),
            fadeOutDuration: const Duration(milliseconds: 80),
            placeholder: (_, _) => placeholder,
            errorWidget: (_, _, _) => placeholder,
          );

    return circle
        ? ClipOval(child: image)
        : ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
  }
}
