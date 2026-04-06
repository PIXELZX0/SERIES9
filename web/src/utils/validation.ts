import { isAddress, parseUnits, type Address, type Hex } from 'viem';

export function parseAddressStrict(value: string): Address {
  const trimmed = value.trim();
  if (!isAddress(trimmed)) {
    throw new Error('INVALID_ADDRESS');
  }

  return trimmed;
}

export function parsePositiveTokenAmount(value: string, decimals = 18): bigint {
  const trimmed = value.trim();

  if (!trimmed) {
    throw new Error('INVALID_AMOUNT');
  }

  const amount = parseUnits(trimmed, decimals);

  if (amount <= 0n) {
    throw new Error('INVALID_AMOUNT');
  }

  return amount;
}

export function parseNonNegativeBps(value: string): number {
  const trimmed = value.trim();
  const parsed = Number(trimmed);

  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 1000) {
    throw new Error('INVALID_BPS');
  }

  return parsed;
}

export function parseHexOrDefault(value: string): Hex {
  const trimmed = value.trim();
  const candidate = trimmed.length === 0 ? '0x' : trimmed;

  if (!/^0x([0-9a-fA-F]{2})*$/.test(candidate)) {
    throw new Error('INVALID_HEX');
  }

  return candidate as Hex;
}

export function parseBooleanFromSelect(value: string): boolean {
  if (value === 'true') {
    return true;
  }

  if (value === 'false') {
    return false;
  }

  throw new Error('INVALID_BOOLEAN');
}
