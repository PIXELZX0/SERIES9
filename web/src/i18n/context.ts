import { createContext } from 'react';

import { en } from './en';
import { ko } from './ko';

export const dictionaries = { en, ko };

export type Locale = keyof typeof dictionaries;
export type MessageKey = keyof typeof en;

export type I18nContextValue = {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (key: MessageKey) => string;
};

export const I18nContext = createContext<I18nContextValue | undefined>(undefined);

export function getInitialLocale(): Locale {
  if (typeof navigator !== 'undefined' && navigator.language.toLowerCase().startsWith('ko')) {
    return 'ko';
  }

  return 'en';
}
