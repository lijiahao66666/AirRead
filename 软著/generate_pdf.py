#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将源码文本转换为软著申请用的PDF文件
要求：
- A4纸张
- 每页不少于50行代码
- 前30页+后30页，共60页
- 页眉显示软件名称和版本
- 页脚显示页码
"""

import os
from pathlib import Path
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.colors import black, gray
from reportlab.pdfgen import canvas

# 注册中文字体
font_paths = [
    r'C:\Windows\Fonts\simhei.ttf',  # 黑体
    r'C:\Windows\Fonts\simsun.ttc',  # 宋体
    r'C:\Windows\Fonts\msyh.ttc',    # 微软雅黑
    r'C:\Windows\Fonts\simkai.ttf',  # 楷体
]

chinese_font = None
for fp in font_paths:
    if os.path.exists(fp):
        try:
            font_name = os.path.basename(fp).split('.')[0]
            pdfmetrics.registerFont(TTFont(font_name, fp))
            chinese_font = font_name
            print(f'成功注册字体: {font_name} ({fp})')
            break
        except Exception as e:
            print(f'注册字体失败 {fp}: {e}')
            continue

if not chinese_font:
    print('警告: 未找到中文字体，将使用默认字体')
    chinese_font = 'Helvetica'

# 文件路径
INPUT_FILE = Path(r'c:\Users\28679\traeProjects\AirRead\软著\source_code_for_ruanzhu_v2.txt')
OUTPUT_FILE = Path(r'c:\Users\28679\traeProjects\AirRead\软著\AirRead_源码_v2.pdf')

# 页面设置
PAGE_WIDTH, PAGE_HEIGHT = A4
MARGIN_LEFT = 20 * mm
MARGIN_RIGHT = 20 * mm
MARGIN_TOP = 25 * mm
MARGIN_BOTTOM = 20 * mm

# 代码字体设置
CODE_FONT_SIZE = 8  # 代码字体大小
CODE_LINE_HEIGHT = 13.5  # 每行代码的高度（点）
LINES_PER_PAGE = 55   # 每页代码行数

# 可用区域
CONTENT_WIDTH = PAGE_WIDTH - MARGIN_LEFT - MARGIN_RIGHT
CONTENT_HEIGHT = PAGE_HEIGHT - MARGIN_TOP - MARGIN_BOTTOM


def split_code_into_pages(lines, lines_per_page):
    """将代码行分割成每页固定行数的列表"""
    pages = []
    current_page = []

    for line in lines:
        current_page.append(line)
        if len(current_page) >= lines_per_page:
            pages.append(current_page)
            current_page = []

    # 处理最后一页（不足50行时，用空行填充）
    if current_page:
        while len(current_page) < lines_per_page:
            current_page.append('')
        pages.append(current_page)

    return pages


def draw_page(c, page_lines, page_num, total_pages):
    """绘制一页内容"""
    # 页眉
    c.setFont(chinese_font, 9)
    c.setFillColor(gray)
    header_text = f'灵阅 AirRead - 源程序鉴别材料'
    c.drawCentredString(PAGE_WIDTH / 2, PAGE_HEIGHT - 15, header_text)

    # 绘制代码行
    c.setFont('Courier', CODE_FONT_SIZE)
    c.setFillColor(black)

    y = PAGE_HEIGHT - MARGIN_TOP
    for line in page_lines:
        # 处理中文字体显示
        # 如果行中包含中文字符，使用注册的中文字体
        has_chinese = any('\u4e00' <= ch <= '\u9fff' for ch in line)
        if has_chinese:
            c.setFont(chinese_font, CODE_FONT_SIZE)
        else:
            c.setFont('Courier', CODE_FONT_SIZE)

        # 截断过长的行
        max_chars = int(CONTENT_WIDTH / (CODE_FONT_SIZE * 0.6))
        display_line = line[:max_chars]

        c.drawString(MARGIN_LEFT, y, display_line)
        y -= CODE_LINE_HEIGHT

    # 页脚
    c.setFont(chinese_font, 9)
    c.setFillColor(gray)
    footer_text = f'- {page_num} -'
    c.drawCentredString(PAGE_WIDTH / 2, MARGIN_BOTTOM - 10, footer_text)


def create_pdf():
    """生成PDF文件"""
    # 读取源码文本
    with open(INPUT_FILE, 'r', encoding='utf-8') as f:
        content = f.read()

    lines = content.split('\n')
    print(f'源码总行数: {len(lines)}')

    # 分割成每页55行
    pages = split_code_into_pages(lines, LINES_PER_PAGE)
    print(f'总页数: {len(pages)}')

    # 检查页数要求
    if len(pages) > 60:
        print(f'警告: 页数({len(pages)})超过60页限制，需要进一步精简代码')
        return
    elif len(pages) < 60:
        print(f'提示: 页数({len(pages)})不足60页，但软著要求通常是前30页+后30页')
        print('      如果总页数≤60页，可以提交全部代码')

    # 创建PDF
    c = canvas.Canvas(str(OUTPUT_FILE), pagesize=A4)

    total_pages = len(pages)
    for page_idx, page_lines in enumerate(pages):
        draw_page(c, page_lines, page_idx + 1, total_pages)
        c.showPage()

    c.save()
    print(f'PDF生成成功: {OUTPUT_FILE}')
    print(f'总页数: {total_pages}')

    # 验证文件
    file_size = os.path.getsize(OUTPUT_FILE)
    print(f'文件大小: {file_size / 1024:.1f} KB')


if __name__ == '__main__':
    create_pdf()
