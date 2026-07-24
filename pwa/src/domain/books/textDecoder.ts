import * as Encoding from 'encoding-japanese';

export function decodeText(bytes: Uint8Array): string {
  if (bytes.length === 0) return '';

  const encoding = Encoding.detect(Array.from(bytes));
  if (encoding === 'UTF8' || encoding === 'ASCII') {
    try {
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } catch {
      // Continue with the browser's Chinese-compatible decoder below.
    }
  }

  for (const label of ['gb18030', 'gbk', 'gb2312']) {
    let decoder: TextDecoder;
    try {
      decoder = new TextDecoder(label, { fatal: true });
    } catch {
      continue;
    }
    try {
      return decoder.decode(bytes);
    } catch {
      throw new Error('文本编码无效，无法按 UTF-8 或 GBK/GB18030 解码');
    }
  }

  throw new Error('当前浏览器不支持 GBK/GB18030 文本解码');
}
