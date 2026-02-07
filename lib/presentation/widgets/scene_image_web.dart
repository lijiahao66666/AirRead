import 'package:flutter/material.dart';

Widget buildSceneImage(String path, {BoxFit fit = BoxFit.cover}) {
  return Container(
    color: Colors.black.withOpacity(0.04),
    alignment: Alignment.center,
    child: const Icon(Icons.image_not_supported_outlined),
  );
}

