import { Languages, X } from 'lucide-react';

type SelectionActionsProps = { visible: boolean; loading?: boolean; onTranslate: () => void; onDismiss: () => void };

export function SelectionActions({ visible, loading = false, onTranslate, onDismiss }: SelectionActionsProps) {
  if (!visible) return null;
  return <div className="selection-actions" role="toolbar" aria-label="选中文本操作"><button type="button" onClick={onTranslate} disabled={loading} aria-label="翻译选中文本"><Languages size={15} /> {loading ? '翻译中…' : '翻译'}</button><button type="button" onClick={onDismiss} aria-label="关闭选中文本操作"><X size={14} /></button></div>;
}
