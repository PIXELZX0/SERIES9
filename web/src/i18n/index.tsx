import { createContext, useContext, useMemo, useState, type ReactNode } from 'react';

import { en } from './en';
import { ko } from './ko';

const dictionaries = { en, ko };

export type Locale = keyof typeof dictionaries;
export type MessageKey = keyof typeof en;

type I18nContextValue = {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (key: MessageKey) => string;
};

const I18nContext = createContext<I18nContextValue | undefined>(undefined);

function getInitialLocale(): Locale {
  if (typeof navigator !== 'undefined' && navigator.language.toLowerCase().startsWith('ko')) {
    return 'ko';
  }

  return 'en';
}

export function I18nProvider({ children }: { children: ReactNode }): ReactNode {
  const [locale, setLocale] = useState<Locale>(getInitialLocale);

  const value = useMemo<I18nContextValue>(() => {
    return {
      locale,
      setLocale,
      t: (key) => dictionaries[locale][key],
    };
  }, [locale]);

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nContextValue {
  const context = useContext(I18nContext);

  if (!context) {
    throw new Error('useI18n must be used within I18nProvider');
  }

  return context;
}
