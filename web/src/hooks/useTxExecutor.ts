import { useCallback, useEffect, useMemo, useState } from 'react';
import { useWaitForTransactionReceipt, useWriteContract } from 'wagmi';

import { getErrorDetails, getFriendlyErrorKey, type FriendlyErrorKey } from '../utils/errors';

type WriteRequest = Parameters<ReturnType<typeof useWriteContract>['writeContractAsync']>[0];

type TxExecutorOptions = {
  onMined?: () => void;
};

export function useTxExecutor(options?: TxExecutorOptions) {
  const { onMined } = options ?? {};
  const { writeContractAsync, isPending: isWalletPrompt } = useWriteContract();

  const [actionLabel, setActionLabel] = useState('');
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>();
  const [lastMinedHash, setLastMinedHash] = useState<`0x${string}` | undefined>();
  const [errorKey, setErrorKey] = useState<FriendlyErrorKey | null>(null);
  const [errorDetail, setErrorDetail] = useState<string | null>(null);

  const receipt = useWaitForTransactionReceipt({
    hash: txHash,
    query: {
      enabled: Boolean(txHash),
    },
  });

  useEffect(() => {
    if (!receipt.isSuccess || !txHash || txHash === lastMinedHash) {
      return;
    }

    setLastMinedHash(txHash);
    onMined?.();
  }, [lastMinedHash, onMined, receipt.isSuccess, txHash]);

  const execute = useCallback(
    async (label: string, request: WriteRequest) => {
      setActionLabel(label);
      setErrorKey(null);
      setErrorDetail(null);

      try {
        const hash = await writeContractAsync(request);
        setTxHash(hash);
        return hash;
      } catch (error) {
        setErrorKey(getFriendlyErrorKey(error));
        setErrorDetail(getErrorDetails(error));
        return undefined;
      }
    },
    [writeContractAsync],
  );

  const reset = useCallback(() => {
    setErrorKey(null);
    setErrorDetail(null);
    setActionLabel('');
    setTxHash(undefined);
  }, []);

  return useMemo(
    () => ({
      execute,
      reset,
      actionLabel,
      txHash,
      errorKey,
      errorDetail,
      isWalletPrompt,
      isConfirming: receipt.isLoading,
      isSuccess: receipt.isSuccess,
    }),
    [
      actionLabel,
      errorDetail,
      errorKey,
      execute,
      isWalletPrompt,
      receipt.isLoading,
      receipt.isSuccess,
      reset,
      txHash,
    ],
  );
}
