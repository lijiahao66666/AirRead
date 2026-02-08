import 'dart:io';

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
  return Image.file(
    File(p),
    fit: fit,
    errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image)),
  );
}
