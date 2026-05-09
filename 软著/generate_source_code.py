#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成软著申请用的精简源码PDF
要求：前30页+后30页，共60页，每页不少于50行
"""

import os
import re
from pathlib import Path

# 基础路径
BASE_DIR = Path(r'c:\Users\28679\traeProjects\AirRead\client\lib')
OUTPUT_FILE = Path(r'c:\Users\28679\traeProjects\AirRead\软著\source_code_for_ruanzhu.txt')

# 目标：约3000行（60页×50行），留一些余量
TARGET_LINES = 2800
MAX_LINES = 3000


def extract_class_skeleton(content, max_keep_lines=200):
    """提取类的骨架：保留类定义、关键方法签名，删除方法体细节"""
    lines = content.split('\n')
    result = []
    in_method_body = False
    brace_depth = 0
    method_indent = ''
    kept_methods = 0
    max_methods = 6  # 每个类最多保留6个关键方法

    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # 保留import和包声明
        if stripped.startswith('import ') or stripped.startswith('export ') or stripped.startswith('library '):
            result.append(line)
            i += 1
            continue

        # 保留顶层函数定义（不在类中的函数）
        if not in_method_body and re.match(r'^(\w+\s+)?\w+\s+\w+\s*\(', stripped) and '{' in stripped:
            result.append(line)
            # 跳过函数体
            j = i + 1
            bd = 1
            while j < len(lines) and bd > 0:
                for ch in lines[j]:
                    if ch == '{':
                        bd += 1
                    elif ch == '}':
                        bd -= 1
                j += 1
            result.append('  // ... 函数实现省略 ...')
            result.append('}')
            i = j
            continue

        # 保留类/枚举/抽象类/mixin定义行
        if re.match(r'^(abstract\s+)?class\s+\w+', stripped) or \
           re.match(r'^enum\s+\w+', stripped) or \
           re.match(r'^typedef\s+', stripped) or \
           re.match(r'^mixin\s+\w+', stripped) or \
           re.match(r'^extension\s+', stripped):
            result.append(line)
            i += 1
            continue

        # 保留字段声明（以final/const/static/late/var开头，以分号结尾）
        if re.match(r'^(final|const|static|late|var)\s+', stripped) and stripped.endswith(';'):
            result.append(line)
            i += 1
            continue

        # 保留类型字段声明（如 String name;）
        if re.match(r'^\w+\s+\w+\s*(=.*)?;', stripped) and not stripped.startswith('if') and not stripped.startswith('for') and not stripped.startswith('while'):
            result.append(line)
            i += 1
            continue

        # 保留getter声明（不包含方法体的getter）
        if re.match(r'^(\w+\s+)?get\s+\w+\s*=>', stripped):
            result.append(line)
            i += 1
            continue

        # 保留注释中的功能说明（/// 开头）
        if stripped.startswith('///'):
            result.append(line)
            i += 1
            continue

        # 保留factory构造函数声明
        if stripped.startswith('factory ') and '(' in stripped:
            result.append(line)
            i += 1
            continue

        # 保留普通构造函数声明（如 ClassName(...) 或 ClassName.name(...)）
        if re.match(r'^(const\s+)?\w+\.(\w+)?\s*\(', stripped):
            result.append(line)
            i += 1
            continue

        # 检测方法定义 - 更精确的模式
        # 匹配：返回类型 方法名(参数) {
        method_match = re.match(r'^(\s*)(@override\s+)?(static\s+)?(\w+(<[^>]+>)?\s+)?(\w+)\s*\([^)]*\)\s*(async\s*)?\{', stripped)
        if method_match and not in_method_body and kept_methods < max_methods:
            indent = method_match.group(1)
            result.append(line)
            method_indent = indent
            in_method_body = True
            brace_depth = 1
            kept_methods += 1

            # 找到方法体的结束
            j = i + 1
            while j < len(lines) and brace_depth > 0:
                for ch in lines[j]:
                    if ch == '{':
                        brace_depth += 1
                    elif ch == '}':
                        brace_depth -= 1
                j += 1
            result.append(method_indent + '  // ... 方法实现省略 ...')
            result.append(method_indent + '}')
            i = j
            in_method_body = False
            continue

        # 保留空行（但限制连续空行）
        if not stripped:
            if len(result) > 0 and result[-1].strip():
                result.append(line)
            i += 1
            continue

        i += 1

    return '\n'.join(result)


def smart_truncate(content, target_lines, file_name):
    """智能截断文件内容"""
    lines = content.split('\n')

    if len(lines) <= target_lines:
        return content

    # 对于超大文件，采用骨架提取
    if len(lines) > 500:
        skeleton = extract_class_skeleton(content, target_lines)
        skeleton_lines = len(skeleton.split('\n'))
        if skeleton_lines <= target_lines:
            return skeleton
        # 如果骨架还是太大，进一步截断
        if skeleton_lines > target_lines:
            skeleton_lines_list = skeleton.split('\n')
            return '\n'.join(skeleton_lines_list[:target_lines])

    # 对于中等文件，保留前半部分和后半部分的关键代码
    head_count = int(target_lines * 0.4)
    tail_count = int(target_lines * 0.4)

    head = lines[:head_count]
    tail = lines[-tail_count:]

    result = head + [
        '',
        '// ============================================================',
        f'// ... {file_name} 中间部分代码省略 ({len(lines) - head_count - tail_count} 行) ...',
        '// ============================================================',
        ''
    ] + tail

    return '\n'.join(result)


def main():
    # 定义要包含的文件及其优先级和最大行数
    # 按照软著说明书中的功能模块组织
    files_config = [
        # ===== 核心入口 =====
        ('main.dart', 80),

        # ===== 数据模型层 =====
        ('data/models/book.dart', 120),

        # ===== 数据库层 =====
        ('data/database/database_helper.dart', 153),

        # ===== 书架管理功能 =====
        ('presentation/providers/books_provider.dart', 200),
        ('presentation/pages/bookshelf/bookshelf_page.dart', 250),

        # ===== 阅读引擎功能 =====
        ('presentation/pages/reader/reader_page.dart', 350),  # 超大文件，大幅精简
        ('presentation/pages/reader/widgets/reader_paragraph.dart', 14),

        # ===== 翻译功能 =====
        ('ai/translation/translation_types.dart', 46),
        ('ai/translation/translation_service.dart', 180),
        ('presentation/providers/translation_provider.dart', 250),  # 大文件，精简
        ('presentation/pages/reader/widgets/translation_sheet.dart', 120),

        # ===== 朗读功能 =====
        ('ai/tencent_tts/tencent_tts_client.dart', 180),
        ('presentation/providers/read_aloud_provider.dart', 250),  # 大文件，精简

        # ===== AI问答功能 =====
        ('ai/reading/qa_service.dart', 180),

        # ===== AI配图功能 =====
        ('ai/illustration/illustration_service.dart', 180),
        ('presentation/widgets/illustration_panel.dart', 200),  # 大文件，精简

        # ===== AI模型管理 =====
        ('presentation/providers/ai_model_provider.dart', 120),

        # ===== 额外补充文件（增加页数到接近60页） =====
        ('ai/local_llm/llm_client.dart', 50),
        ('ai/local_llm/mnn_client.dart', 70),
        ('ai/hunyuan/hunyuan_text_client.dart', 70),
        ('ai/hunyuan/hunyuan_image_client.dart', 70),
        ('presentation/widgets/ai_hud.dart', 90),
    ]

    all_content = []
    total_lines = 0
    file_stats = []

    for rel_path, max_lines in files_config:
        file_path = BASE_DIR / rel_path
        if not file_path.exists():
            print(f'警告: 文件不存在 {rel_path}')
            continue

        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()

        original_lines = len(content.split('\n'))

        # 智能截断
        truncated = smart_truncate(content, max_lines, rel_path)
        final_lines = len(truncated.split('\n'))

        # 添加文件分隔符
        header = f"""
// ============================================================================
// 文件: {rel_path}
// 原始行数: {original_lines} | 保留行数: {final_lines}
// ============================================================================
"""
        file_content = header + '\n' + truncated
        all_content.append(file_content)
        total_lines += final_lines + 4  # 加上header的行数
        file_stats.append((rel_path, original_lines, final_lines))

    # 写入输出文件
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        f.write('\n'.join(all_content))

    # 打印统计
    print('=' * 60)
    print('软著源码生成统计')
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


if __name__ == '__main__':
    main()
