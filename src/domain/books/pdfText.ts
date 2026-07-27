type PdfMetadata = { info?: { Title?: string; Author?: string } };

export type ExtractedPdfText = {
  title?: string;
  author?: string;
  text: string;
};

const cleanMetadata = (value: unknown): string | undefined => typeof value === 'string' && value.trim() ? value.trim() : undefined;

export async function extractPdfText(bytes: Uint8Array): Promise<ExtractedPdfText> {
  const { getDocument, GlobalWorkerOptions } = await import('pdfjs-dist/legacy/build/pdf.mjs');
  GlobalWorkerOptions.workerSrc = new URL('pdfjs-dist/legacy/build/pdf.worker.mjs', import.meta.url).toString();

  const loadingTask = getDocument({ data: Uint8Array.from(bytes) });
  const pdf = await loadingTask.promise;
  try {
    const metadata = await pdf.getMetadata() as PdfMetadata;
    const pages: string[] = [];
    for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber += 1) {
      const page = await pdf.getPage(pageNumber);
      const content = await page.getTextContent();
      const pageText = content.items
        .reduce((text, item) => 'str' in item && typeof item.str === 'string' ? `${text}${item.str}${item.hasEOL ? '\n' : ' '}` : text, '')
        .replace(/[ \t]+\n/gu, '\n')
        .replace(/\n{3,}/gu, '\n\n')
        .trim();
      if (pageText) pages.push(`# 第 ${pageNumber} 页\n\n${pageText}`);
    }
    if (pages.length === 0) throw new Error('未从 PDF 提取到可选文本。扫描版 PDF 暂不支持，请先进行 OCR。');
    return {
      title: cleanMetadata(metadata.info?.Title),
      author: cleanMetadata(metadata.info?.Author),
      text: pages.join('\n\n'),
    };
  } finally {
    await pdf.destroy();
  }
}
