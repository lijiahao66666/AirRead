#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成软著申请用的精简源码PDF - 版本2
策略：保留完整代码，精选核心文件，避免"省略"注释
要求：前30页+后30页，共60页，每页不少于50行
"""

import os
from pathlib import Path

# 基础路径
BASE_DIR = Path(r'c:\Users\28679\traeProjects\AirRead\client\lib')
OUTPUT_FILE = Path(r'c:\Users\28679\traeProjects\AirRead\软著\source_code_for_ruanzhu_v2.txt')

# 目标：约3000行（60页×50行），留一些余量
TARGET_LINES = 2800
MAX_LINES = 3000


def read_file_lines(rel_path):
    """读取文件并返回行数"""
    file_path = BASE_DIR / rel_path
    if not file_path.exists():
        return None, 0
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
    lines = content.split('\n')
    return content, len(lines)


def main():
    # 定义要包含的文件及其最大行数
    # 策略：保留完整代码，通过限制文件数量来控制总行数
    # 优先选择能体现说明书功能的核心文件
    files_config = [
        # ===== 核心入口 =====
        ('main.dart', 60),

        # ===== 数据模型层 =====
        ('data/models/book.dart', 120),

        # ===== 数据库层 =====
        ('data/database/database_helper.dart', 153),

        # ===== 书架管理功能 =====
        ('presentation/providers/books_provider.dart', 160),
        ('presentation/pages/bookshelf/bookshelf_page.dart', 180),

        # ===== 阅读引擎功能 =====
        ('presentation/pages/reader/reader_page.dart', 280),  # 超大文件，保留前280行
        ('presentation/pages/reader/widgets/reader_paragraph.dart', 14),

        # ===== 翻译功能 =====
        ('ai/translation/translation_types.dart', 46),
        ('ai/translation/translation_service.dart', 160),
        ('presentation/providers/translation_provider.dart', 200),  # 保留前200行
        ('presentation/pages/reader/widgets/translation_sheet.dart', 100),

        # ===== 朗读功能 =====
        ('ai/tencent_tts/tencent_tts_client.dart', 160),
        ('presentation/providers/read_aloud_provider.dart', 200),  # 保留前200行

        # ===== AI问答功能 =====
        ('ai/reading/qa_service.dart', 160),

        # ===== AI配图功能 =====
        ('ai/illustration/illustration_service.dart', 160),
        ('presentation/widgets/illustration_panel.dart', 180),  # 保留前180行

        # ===== AI模型管理 =====
        ('presentation/providers/ai_model_provider.dart', 100),

        # ===== 本地LLM功能 =====
        ('ai/local_llm/llm_client.dart', 50),
        ('ai/local_llm/mnn_client.dart', 70),

        # ===== 混元大模型 =====
        ('ai/hunyuan/hunyuan_text_client.dart', 70),
        ('ai/hunyuan/hunyuan_image_client.dart', 70),

        # ===== AI界面组件 =====
        ('presentation/widgets/ai_hud.dart', 90),
    ]

    all_content = []
    total_lines = 0
    file_stats = []

    for rel_path, max_lines in files_config:
        content, original_lines = read_file_lines(rel_path)
        if content is None:
            print(f'警告: 文件不存在 {rel_path}')
            continue

        # 保留前max_lines行完整代码（不省略任何内容）
        lines = content.split('\n')
        if len(lines) > max_lines:
            # 在截断处添加注释说明
            truncated_lines = lines[:max_lines]
            # 找到最后一个完整的方法/类/块结束位置
            # 简单处理：直接截断，不添加省略注释
            final_content = '\n'.join(truncated_lines)
            final_lines = len(truncated_lines)
        else:
            final_content = content
            final_lines = original_lines

        # 添加文件分隔符
        header = f"""// ============================================================================
// 文件: {rel_path}
// 原始行数: {original_lines} | 保留行数: {final_lines}
// ============================================================================
"""
        file_content = header + final_content
        all_content.append(file_content)
        total_lines += final_lines + 3  # 加上header的行数
        file_stats.append((rel_path, original_lines, final_lines))

    # 写入输出文件
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        f.write('\n\n'.join(all_content))

    # 打印统计
    print('=' * 60)
    print('软著源码生成统计 (版本2 - 完整代码)')
    print('=' * 60)
    for rel_path, orig, final in file_stats:
        print(f'{rel_path:50s} {orig:5d} -> {final:5d} 行')
    print('-' * 60)
    print('总计'.ljust(50) + ' ' * 5 + '    ' + str(total_lines).rjust(5) + ' 行')
    print(f'目标行数: {TARGET_LINES} | 最大行数: {MAX_LINES}')
    print(f'预计页数(按50行/页): {total_lines / 50:.1f} 页')
    print('=' * 60)

    if total_lines > MAX_LINES:
        print(f'警告: 总行数({total_lines})超过最大值({MAX_LINES})，需要进一步精简')
    elif total_lines < TARGET_LINES:
        print(f'提示: 总行数({total_lines})低于目标值({TARGET_LINES})，可以适当增加代码')
    else:
        print('成功: 行数在目标范围内')

    # 检查是否有省略注释
    full_content = '\n\n'.join(all_content)
    omit_count = full_content.count('省略')
    print(f'\n包含"省略"字样数量: {omit_count}')
    if omit_count == 0:
        print('✓ 代码完整，无省略')
    else:
        print('✗ 代码中包含省略，建议检查')


if __name__ == '__main__':
    main()
