export type FriendlyErrorKey =
  | 'walletRejected'
  | 'insufficientFunds'
  | 'executionReverted'
  | 'unknownError';

function toMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  if (typeof error === 'string') {
    return error;
  }

  return JSON.stringify(error);
}

export function getFriendlyErrorKey(error: unknown): FriendlyErrorKey {
  const message = toMessage(error).toLowerCase();

  if (message.includes('user rejected') || message.includes('user denied')) {
    return 'walletRejected';
  }

  if (message.includes('insufficient funds')) {
    return 'insufficientFunds';
  }

  if (message.includes('revert') || message.includes('execution reverted')) {
    return 'executionReverted';
  }

  return 'unknownError';
}

export function getErrorDetails(error: unknown): string {
  const message = toMessage(error);
  return message.length > 420 ? `${message.slice(0, 420)}...` : message;
}
