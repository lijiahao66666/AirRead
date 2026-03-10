import 'dart:math';
import 'package:flutter/material.dart';

class WindConfig {
  double density; // 0.5 to 2.0
  double sizeScale; // 0.8 to 1.5
  double speedScale; // 0.5 to 2.0
  
  WindConfig({
    this.density = 1.0,
    this.sizeScale = 1.0,
    this.speedScale = 1.0,
  });
}

class WindStream {
  double x;
  double y;
  final double baseSpeed;
  final double baseWidth;
  final double baseLength;
  final double opacity;
  double progress; // 0.0 to 1.0
  
  // Dynamic properties based on config
  double currentSpeed = 0;
  double currentWidth = 0;
  double currentLength = 0;

  WindStream({
    required this.x,
    required this.y,
    required this.baseSpeed,
    required this.baseWidth,
    required this.baseLength,
    required this.opacity,
    this.progress = 0.0,
  });

  void update(WindConfig config) {
    currentSpeed = baseSpeed * config.speedScale;
    currentWidth = baseWidth * config.sizeScale;
    currentLength = baseLength * config.sizeScale;
    
    y -= currentSpeed;
    progress += 0.01 * config.speedScale;
  }
}

class AirFlowController extends ChangeNotifier {
  final List<WindStream> streams = [];
  final Random _random = Random();
  Size canvasSize;
  WindConfig config;

  AirFlowController({
    required this.canvasSize,
    WindConfig? config,
  }) : config = config ?? WindConfig();

  void updateSize(Size newSize) {
    canvasSize = newSize;
    notifyListeners();
  }

  void updateConfig({double? density, double? sizeScale, double? speedScale}) {
    if (density != null) config.density = density;
    if (sizeScale != null) config.sizeScale = sizeScale;
    if (speedScale != null) config.speedScale = speedScale;
    notifyListeners();
  }

  void spawnStream() {
    // Strict Limit: Only 1 stream at a time as requested
    if (streams.isNotEmpty) return;

    final startX = _random.nextDouble() * canvasSize.width;
    final startY = canvasSize.height + 200; // Start further below

    streams.add(WindStream(
      x: startX,
      y: startY,
      baseSpeed: 2.0 + _random.nextDouble() * 3.0,
      baseWidth: 30 + _random.nextDouble() * 20,
      baseLength: 200 + _random.nextDouble() * 300,
      opacity: 0.15 + _random.nextDouble() * 0.2, // Reduced visual intensity (opacity)
    ));
  }

  void updateParticles() {
    for (var i = streams.length - 1; i >= 0; i--) {
      streams[i].update(config);
      // Remove if completely off screen (accounting for length)
      if (streams[i].y < -streams[i].currentLength) {
        streams.removeAt(i);
      }
    }
    
    // Spawn new streams with reduced frequency
    // 1% chance per frame (approx once every 2 seconds at 60fps)
    if (_random.nextDouble() < 0.01) { 
      spawnStream();
    }
    notifyListeners();
  }
}
