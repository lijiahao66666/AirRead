import { useEffect, useRef, useState } from 'react';

type DailyMinutesInputProps = {
  value: number;
  onChange: (minutes: number) => void;
};

const isValidDailyMinutes = (value: number): boolean => Number.isInteger(value) && value >= 5 && value <= 180;

export function DailyMinutesInput({ value, onChange }: DailyMinutesInputProps) {
  const [draft, setDraft] = useState(String(value));
  const updateTimer = useRef<number | undefined>(undefined);

  useEffect(() => setDraft(String(value)), [value]);
  useEffect(() => () => window.clearTimeout(updateTimer.current), []);

  const commit = (candidate = draft) => {
    window.clearTimeout(updateTimer.current);
    const minutes = Number(candidate);
    if (!isValidDailyMinutes(minutes)) {
      setDraft(String(value));
      return;
    }
    if (minutes !== value) onChange(minutes);
  };

  const scheduleUpdate = (candidate: string) => {
    window.clearTimeout(updateTimer.current);
    const minutes = Number(candidate);
    if (!isValidDailyMinutes(minutes) || minutes === value) return;
    updateTimer.current = window.setTimeout(() => onChange(minutes), 700);
  };

  return <input aria-label="每日可用分钟数" type="number" min="5" max="180" step="1" inputMode="numeric" value={draft} onChange={(event) => { setDraft(event.target.value); scheduleUpdate(event.target.value); }} onBlur={() => commit()} onKeyDown={(event) => { if (event.key === 'Enter') { event.currentTarget.blur(); } }} />;
}
