import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useSendTransaction, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';

import { getErrorDetails, getFriendlyErrorKey, type FriendlyErrorKey } from '../utils/errors';

type WriteRequest = Parameters<ReturnType<typeof useWriteContract>['writeContractAsync']>[0];
type SendRequest = Parameters<ReturnType<typeof useSendTransaction>['sendTransactionAsync']>[0];

type TxExecutorOptions = {
  onMined?: () => void;
};

export function useTxExecutor(options?: TxExecutorOptions) {
  const { onMined } = options ?? {};
  const { writeContractAsync, isPending: isWalletPrompt } = useWriteContract();
  const { sendTransactionAsync, isPending: isSendPrompt } = useSendTransaction();

  const [actionLabel, setActionLabel] = useState('');
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>();
  const lastMinedHashRef = useRef<`0x${string}` | undefined>(undefined);
  const [errorKey, setErrorKey] = useState<FriendlyErrorKey | null>(null);
  const [errorDetail, setErrorDetail] = useState<string | null>(null);

  const receipt = useWaitForTransactionReceipt({
    hash: txHash,
    query: {
      enabled: Boolean(txHash),
    },
  });

  useEffect(() => {
    if (!receipt.isSuccess || !txHash || txHash === lastMinedHashRef.current) {
      return;
    }

    lastMinedHashRef.current = txHash;
    onMined?.();
  }, [onMined, receipt.isSuccess, txHash]);

  const execute = useCallback(
    async <TRequest extends WriteRequest>(label: string, request: TRequest) => {
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

  const executeSend = useCallback(
    async (label: string, request: SendRequest) => {
      setActionLabel(label);
      setErrorKey(null);
      setErrorDetail(null);

      try {
        const hash = await sendTransactionAsync(request);
        setTxHash(hash);
        return hash;
      } catch (error) {
        setErrorKey(getFriendlyErrorKey(error));
        setErrorDetail(getErrorDetails(error));
        return undefined;
      }
    },
    [sendTransactionAsync],
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
      executeSend,
      reset,
      actionLabel,
      txHash,
      errorKey,
      errorDetail,
      isWalletPrompt: isWalletPrompt || isSendPrompt,
      isConfirming: receipt.isLoading,
      isSuccess: receipt.isSuccess,
    }),
    [
      actionLabel,
      errorDetail,
      errorKey,
      execute,
      executeSend,
      isSendPrompt,
      isWalletPrompt,
      receipt.isLoading,
      receipt.isSuccess,
      reset,
      txHash,
    ],
  );
}
