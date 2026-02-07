import 'dart:io';

import 'package:flutter/material.dart';

Widget buildSceneImage(String path, {BoxFit fit = BoxFit.cover}) {
  return Image.file(
    File(path),
    fit: fit,
    errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image)),
  );
}

