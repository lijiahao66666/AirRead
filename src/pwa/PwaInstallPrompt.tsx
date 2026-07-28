import { Download, Share2 } from 'lucide-react';
import { useEffect, useState } from 'react';

type DeferredInstallPrompt = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>;
};

const isStandalone = () => window.matchMedia?.('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone === true;
const isAppleMobile = () => /iPad|iPhone|iPod/u.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

export function PwaInstallPrompt() {
  const [deferredPrompt, setDeferredPrompt] = useState<DeferredInstallPrompt>();
  const [showAppleGuide, setShowAppleGuide] = useState(() => isAppleMobile() && !isStandalone());
  const [installed, setInstalled] = useState(isStandalone);

  useEffect(() => {
    const onBeforeInstallPrompt = (event: Event) => {
      event.preventDefault();
      setDeferredPrompt(event as DeferredInstallPrompt);
    };
    const onInstalled = () => {
      setInstalled(true);
      setDeferredPrompt(undefined);
      setShowAppleGuide(false);
    };
    window.addEventListener('beforeinstallprompt', onBeforeInstallPrompt);
    window.addEventListener('appinstalled', onInstalled);
    return () => {
      window.removeEventListener('beforeinstallprompt', onBeforeInstallPrompt);
      window.removeEventListener('appinstalled', onInstalled);
    };
  }, []);

  if (installed || (!deferredPrompt && !showAppleGuide)) return null;

  const promptInstallation = async () => {
    if (!deferredPrompt) {
      setShowAppleGuide(true);
      return;
    }
    await deferredPrompt.prompt();
    const choice = await deferredPrompt.userChoice;
    if (choice.outcome === 'accepted') setInstalled(true);
    setDeferredPrompt(undefined);
  };

  return (
    <section className="pwa-install-card" aria-label="安装 AirRead">
      <span className="pwa-install-card__icon" aria-hidden="true">{showAppleGuide ? <Share2 size={18} /> : <Download size={18} />}</span>
      <div>
        <strong>{showAppleGuide ? '添加到主屏幕' : '安装 AirRead'}</strong>
        <p>{showAppleGuide ? '在浏览器的分享菜单中选择“添加到主屏幕”，即可像 App 一样从桌面打开。' : '安装后可从桌面打开，并获得更接近阅读 App 的沉浸体验。'}</p>
      </div>
      <button type="button" onClick={() => { void promptInstallation(); }}>{showAppleGuide ? '查看方法' : '安装'}</button>
    </section>
  );
}
