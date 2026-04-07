import { useMemo, useState, type ReactNode } from 'react';

import { I18nContext, dictionaries, getInitialLocale, type I18nContextValue, type Locale } from './context';

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

export type { Locale, MessageKey } from './context';
