export type PrivateNoteRecord = {
  commitmentHash: `0x${string}`;
  nullifierHash?: `0x${string}`;
  viewTag: `0x${string}`;
  amount: string;
  stealthAddress: `0x${string}`;
  leafIndex?: number;
  createdAt: number;
};

const STORAGE_KEY = 'series9.private.notes';

export function loadPrivateNotes(): PrivateNoteRecord[] {
  if (typeof window === 'undefined') {
    return [];
  }

  const raw = window.localStorage.getItem(STORAGE_KEY);
  if (!raw) {
    return [];
  }

  try {
    const parsed = JSON.parse(raw) as PrivateNoteRecord[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export function savePrivateNotes(notes: PrivateNoteRecord[]): void {
  if (typeof window === 'undefined') {
    return;
  }

  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(notes));
}

export function appendPrivateNote(note: PrivateNoteRecord): PrivateNoteRecord[] {
  const next = [...loadPrivateNotes(), note];
  savePrivateNotes(next);
  return next;
}
