import { formatUnits, type Address } from 'viem';

export function formatTokenAmount(
  value: bigint | undefined,
  decimals = 18,
  maximumFractionDigits = 6,
): string {
  if (value === undefined) {
    return '-';
  }

  const numeric = Number(formatUnits(value, decimals));

  if (!Number.isFinite(numeric)) {
    return formatUnits(value, decimals);
  }

  const minimumVisibleValue = 1 / 10 ** maximumFractionDigits;

  if (numeric > 0 && numeric < minimumVisibleValue) {
    return `<${minimumVisibleValue.toFixed(maximumFractionDigits)}`;
  }

  return new Intl.NumberFormat('en-US', {
    maximumFractionDigits,
  }).format(numeric);
}

export function formatRewardAmount(value: bigint | undefined, decimals = 18): string {
  return formatTokenAmount(value, decimals, 12);
}

export function shortenAddress(address: Address | undefined, size = 4): string {
  if (!address) {
    return '-';
  }

  return `${address.slice(0, size + 2)}...${address.slice(-size)}`;
}

export function equalsAddress(a: string | undefined, b: string | undefined): boolean {
  if (!a || !b) {
    return false;
  }

  return a.toLowerCase() === b.toLowerCase();
}
