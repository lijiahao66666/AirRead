import 'package:flutter/material.dart';

Widget buildSceneImage(String path, {BoxFit fit = BoxFit.cover}) {
  final p = path.trim();
  if (p.startsWith('http://') || p.startsWith('https://')) {
    return Image.network(
      p,
      fit: fit,
      errorBuilder: (_, __, ___) =>
          const Center(child: Icon(Icons.broken_image)),
    );
  }
  return Container(
    color: Colors.black.withOpacity(0.04),
    alignment: Alignment.center,
    child: const Icon(Icons.image_not_supported_outlined),
  );
}
