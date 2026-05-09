#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
检查说明书功能与源码的对应关系
"""

from pathlib import Path

# 源码文件列表
source_files = [
    'main.dart',
    'data/models/book.dart',
    'data/database/database_helper.dart',
    'presentation/providers/books_provider.dart',
    'presentation/pages/bookshelf/bookshelf_page.dart',
    'presentation/pages/reader/reader_page.dart',
    'presentation/pages/reader/widgets/reader_paragraph.dart',
    'ai/translation/translation_types.dart',
    'ai/translation/translation_service.dart',
    'presentation/providers/translation_provider.dart',
    'presentation/pages/reader/widgets/translation_sheet.dart',
    'ai/tencent_tts/tencent_tts_client.dart',
    'presentation/providers/read_aloud_provider.dart',
    'ai/reading/qa_service.dart',
    'ai/illustration/illustration_service.dart',
    'presentation/widgets/illustration_panel.dart',
    'presentation/providers/ai_model_provider.dart',
    'ai/local_llm/llm_client.dart',
    'ai/local_llm/mnn_client.dart',
    'ai/hunyuan/hunyuan_text_client.dart',
    'ai/hunyuan/hunyuan_image_client.dart',
    'presentation/widgets/ai_hud.dart',
]

# 说明书功能列表及对应关键词
manual_features = {
    '书架管理': ['importBooks', 'deleteBook', 'pinSelectedBooks', 'BookImporter', 'BookParser', 'DatabaseHelper', 'bookshelf', '书架', '导入书籍', 'GridView'],
    '阅读引擎': ['ReaderPage', 'ReaderParagraph', 'BookParser', 'buildTxtChaptersFast', 'TextPainter', 'PageView', 'GestureDetector', '阅读器', '翻页', '章节'],
    'AI翻译': ['TranslationService', 'TranslationCache', 'TranslationTaskQueue', 'translate', '翻译', 'Local', 'Online', 'TMT', 'Azure'],
    'AI插图': ['IllustrationService', '插图', 'TextToImage', 'Polling', '轮询', 'image', '图片'],
    'AI问答': ['QaService', '问答', 'ChatCompletions', 'Stream', 'qa', 'question'],
    'TTS语音合成': ['TencentTtsClient', 'TTS', 'WebSocket', 'AudioPlayer', '听书', '朗读', 'tts', '语音'],
    '本地LLM': ['MnnModelDownloader', 'LlmClientMnn', 'AiModelProvider', 'MNN', 'generate', 'generateStream', '断点续传', 'FFI', '本地模型'],
    '混元大模型': ['Hunyuan', 'hunyuan', '腾讯混元', 'TC3-HMAC-SHA256', '混元'],
    '数据库': ['SQLite', 'sqflite', 'books', 'settings', 'insertBook', 'getAllBooks', 'updateBook', 'database'],
    '数据模型': ['Book', 'TranslationConfig', 'AiModel', 'class Book'],
}

# 读取所有源码内容
source_content = {}
base_dir = Path(r'c:\Users\28679\traeProjects\AirRead\软著\source_code_for_ruanzhu_v2.txt')
content = base_dir.read_text(encoding='utf-8')

# 按文件分割 - 修正分隔符
import re
# 匹配文件头: // ============================================================================// 文件: xxx
file_blocks = re.split(r'// =+\n// 文件: ', content)
for f in file_blocks[1:]:  # 跳过第一个空块
    lines = f.split('\n')
    filename = lines[0].strip()
    file_content = '\n'.join(lines[1:])
    source_content[filename] = file_content

print('=' * 80)
print('说明书功能 vs 源码对应关系检查')
print('=' * 80)

missing_features = []

for feature, keywords in manual_features.items():
    found = False
    found_files = []
    for filename, file_content in source_content.items():
        for keyword in keywords:
            if keyword in file_content:
                found = True
                if filename not in found_files:
                    found_files.append(filename)
    
    status = '✓ 已对应' if found else '✗ 未找到'
    print('\n' + feature + ' ' + status)
    if found_files:
        for f in found_files:
            print('  -> ' + f)
    else:
        print('  -> 警告: 未找到对应源码文件')
        missing_features.append(feature)

print('\n' + '=' * 80)
print('源码文件覆盖检查')
print('=' * 80)

# 检查每个源码文件是否对应说明书功能
for filename in source_files:
    matched_features = []
    for feature, keywords in manual_features.items():
        for keyword in keywords:
            if filename in source_content and keyword in source_content[filename]:
                if feature not in matched_features:
                    matched_features.append(feature)
    
    if matched_features:
        features_str = ', '.join(matched_features)
        print(filename.ljust(55) + ' -> ' + features_str)
    else:
        print(filename.ljust(55) + ' -> (通用代码/入口)')

print('\n' + '=' * 80)
print('检查总结')
print('=' * 80)
if missing_features:
    print('警告: 以下功能在源码中未找到明确对应:')
    for f in missing_features:
        print('  - ' + f)
else:
    print('✓ 所有说明书功能在源码中均有对应')

print('\n源码文件总数: ' + str(len(source_content)))
print('说明书功能模块数: ' + str(len(manual_features)))
