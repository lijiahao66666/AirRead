import 'dart:io';
import 'package:flutter/material.dart';

Widget? buildLocalFileImage({
  required String path,
  required BoxFit fit,
  double? width,
  double? height,
  int? cacheWidth,
  int? cacheHeight,
  ImageErrorWidgetBuilder? errorBuilder,
}) {
  return Image.file(
    File(path),
    fit: fit,
    width: width,
    height: height,
    cacheWidth: cacheWidth,
    cacheHeight: cacheHeight,
    errorBuilder: errorBuilder,
  );
}

