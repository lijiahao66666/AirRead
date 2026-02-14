import 'dart:io';

import 'package:airread/ai/illustration/illustration_service.dart';
import 'package:airread/ai/tencentcloud/tencent_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generateIllustrations caps count and strips answer prefix', () async {
    final service = IllustrationService(
      credentials: TencentCredentials.empty(),
      baseStoragePath: Directory.systemTemp.path,
    );

    final paragraphs = <String>[
      '第一段。',
      '第二段。',
      '第三段。',
    ];

    final items = await service.generateIllustrations(
      paragraphs: paragraphs,
      chapterTitle: '测试',
      count: 12,
      useLocalModel: false,
      run: (prompt) async {
        return [
          '1. Answer: 主体；动作；环境；光影；氛围',
          '2. 主体；动作；环境；光影；氛围',
          '3. 主体；动作；环境；光影；氛围',
          '4. 主体；动作；环境；光影；氛围',
        ].join('\n');
      },
      enableThinking: false,
    );

    expect(items.length, 3);
    for (final it in items) {
      final p = (it.prompt ?? '').trim().toLowerCase();
      expect(p.startsWith('answer'), isFalse);
    }
  });

  test('generateIllustrations local keeps <answer> content and removes <think>', () async {
    final service = IllustrationService(
      credentials: TencentCredentials.empty(),
      baseStoragePath: Directory.systemTemp.path,
    );

    final items = await service.generateIllustrations(
      paragraphs: const <String>['他在床边醒来。'],
      chapterTitle: '测试',
      count: 1,
      useLocalModel: true,
      run: (prompt) async {
        return '''
<think>推理过程</think>
<answer>
小纸人；轻轻摇晃；木床上；清晨阳光；温馨。
</answer>
''';
      },
      enableThinking: false,
    );

    expect(items.length, 1);
    final p = (items.single.prompt ?? '').trim();
    expect(p.contains('<think>'), isFalse);
    expect(p.contains('<answer>'), isFalse);
    expect(p.contains('小纸人'), isTrue);
  });

  test('generateIllustrations online does not exceed per-chunk paragraph caps', () async {
    final service = IllustrationService(
      credentials: TencentCredentials.empty(),
      baseStoragePath: Directory.systemTemp.path,
    );

    final paragraphs = <String>[
      '很长' * 3000,
      '短',
      '短',
      '短',
      '短',
      '短',
      '短',
      '短',
    ];

    final items = await service.generateIllustrations(
      paragraphs: paragraphs,
      chapterTitle: '测试',
      count: 8,
      useLocalModel: false,
      run: (prompt) async {
        return [
          '1. 主体；动作；环境；光影；氛围',
          '2. 主体；动作；环境；光影；氛围',
          '3. 主体；动作；环境；光影；氛围',
          '4. 主体；动作；环境；光影；氛围',
          '5. 主体；动作；环境；光影；氛围',
          '6. 主体；动作；环境；光影；氛围',
          '7. 主体；动作；环境；光影；氛围',
          '8. 主体；动作；环境；光影；氛围',
        ].join('\n');
      },
      enableThinking: false,
    );

    expect(items.length, 8);
  });
}
