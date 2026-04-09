import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useMemo, useRef, useState } from 'react';
import {
  useAccount,
  useBalance,
  useBlockNumber,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useReadContracts,
  useSwitchChain,
} from 'wagmi';
import { encodeFunctionData, getAddress, isAddress, maxUint256, zeroAddress, type Address } from 'viem';

import { explorerTxUrl, networkConfig } from './config/chain';
import { contracts } from './config/contracts';
import { managedTokenAbi, ser9Abi, stakingAbi } from './contracts/abi';
import { useTxExecutor } from './hooks/useTxExecutor';
import { type MessageKey } from './i18n';
import { useI18n } from './i18n/useI18n';
import { formatRewardAmount, formatTokenAmount, shortenAddress } from './utils/format';
import { parsePositiveTokenAmount } from './utils/validation';

type ActionModalType = 'ser9Stake' | 'ser9Unstake' | 'monadStake' | 'monadUnstake';

type TokenConfigValue = {
  exists: boolean;
  creator: Address;
  mintRate: bigint;
  feeEnabled: boolean;
};

type TokenMintPolicyValue = {
  maxSupply: bigint;
  maxMultiplierBps: bigint;
  rampStartBps: number;
};

function parseTokenConfig(raw: unknown): TokenConfigValue | null {
  if (!raw) {
    return null;
  }

  if (Array.isArray(raw)) {
    const [exists, creator, mintRate, feeEnabled] = raw;
    if (typeof exists === 'boolean' && typeof creator === 'string' && typeof mintRate === 'bigint') {
      return {
        exists,
        creator: getAddress(creator),
        mintRate,
        feeEnabled: Boolean(feeEnabled),
      };
    }
  }

  if (typeof raw === 'object') {
    const value = raw as {
      exists?: unknown;
      creator?: unknown;
      mintRate?: unknown;
      feeEnabled?: unknown;
    };

    if (
      typeof value.exists === 'boolean' &&
      typeof value.creator === 'string' &&
      typeof value.mintRate === 'bigint' &&
      typeof value.feeEnabled === 'boolean'
    ) {
      return {
        exists: value.exists,
        creator: getAddress(value.creator),
        mintRate: value.mintRate,
        feeEnabled: value.feeEnabled,
      };
    }
  }

  return null;
}

function parseTokenMintPolicy(raw: unknown): TokenMintPolicyValue | null {
  if (!raw) {
    return null;
  }

  if (Array.isArray(raw)) {
    const [maxSupply, maxMultiplierBps, rampStartBps] = raw;
    if (
      typeof maxSupply === 'bigint' &&
      typeof maxMultiplierBps === 'bigint' &&
      (typeof rampStartBps === 'number' || typeof rampStartBps === 'bigint')
    ) {
      return {
        maxSupply,
        maxMultiplierBps,
        rampStartBps: Number(rampStartBps),
      };
    }
  }

  if (typeof raw === 'object') {
    const value = raw as {
      maxSupply?: unknown;
      maxMultiplierBps?: unknown;
      rampStartBps?: unknown;
    };

    if (
      typeof value.maxSupply === 'bigint' &&
      typeof value.maxMultiplierBps === 'bigint' &&
      (typeof value.rampStartBps === 'number' || typeof value.rampStartBps === 'bigint')
    ) {
      return {
        maxSupply: value.maxSupply,
        maxMultiplierBps: value.maxMultiplierBps,
        rampStartBps: Number(value.rampStartBps),
      };
    }
  }

  return null;
}

function MetricCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="metric-card">
      <span className="metric-label">{label}</span>
      <strong className="metric-value">{value}</strong>
    </div>
  );
}

function ManagedTokenCard({ token }: { token: Address }) {
  const { t } = useI18n();

  const tokenConfigRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'tokenConfigs',
    args: [token],
  });

  const tokenMintPolicyRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'tokenMintPolicies',
    args: [token],
  });

  const nameRead = useReadContract({
    address: token,
    abi: managedTokenAbi,
    functionName: 'name',
  });

  const symbolRead = useReadContract({
    address: token,
    abi: managedTokenAbi,
    functionName: 'symbol',
  });

  const feeEnabledRead = useReadContract({
    address: token,
    abi: managedTokenAbi,
    functionName: 'feeEnabled',
  });

  const feeBpsRead = useReadContract({
    address: token,
    abi: managedTokenAbi,
    functionName: 'feeBps',
  });

  const feeRecipientRead = useReadContract({
    address: token,
    abi: managedTokenAbi,
    functionName: 'feeRecipient',
  });

  const totalSupplyRead = useReadContract({
    address: token,
    abi: managedTokenAbi,
    functionName: 'totalSupply',
  });

  const decimalsRead = useReadContract({
    address: token,
    abi: managedTokenAbi,
    functionName: 'decimals',
  });

  const effectiveMintRateRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'effectiveMintRate',
    args: [token],
  });

  const tokenConfig = parseTokenConfig(tokenConfigRead.data);
  const tokenMintPolicy = parseTokenMintPolicy(tokenMintPolicyRead.data);
  const symbol = symbolRead.data ?? '-';

  return (
    <article className="token-card">
      <div className="token-card-head">
        <h4>{nameRead.data ?? symbol}</h4>
        <span className="pill">{symbol}</span>
      </div>

      <div className="token-grid">
        <div>
          <span>{t('tokenAddress')}</span>
          <strong>{shortenAddress(token)}</strong>
        </div>
        <div>
          <span>{t('mintRate')}</span>
          <strong>{formatTokenAmount(tokenConfig?.mintRate)}</strong>
        </div>
        <div>
          <span>{t('effectiveMintRate')}</span>
          <strong>{formatTokenAmount(effectiveMintRateRead.data)}</strong>
        </div>
        <div>
          <span>{t('maxSupply')}</span>
          <strong>
            {tokenMintPolicy?.maxSupply === 0n ? t('unlimited') : formatTokenAmount(tokenMintPolicy?.maxSupply)}
          </strong>
        </div>
        <div>
          <span>{t('maxMultiplierBps')}</span>
          <strong>{tokenMintPolicy?.maxMultiplierBps?.toString() ?? '10000'}</strong>
        </div>
        <div>
          <span>{t('rampStartBps')}</span>
          <strong>{tokenMintPolicy?.rampStartBps?.toString() ?? '0'}</strong>
        </div>
        <div>
          <span>{t('feeEnabled')}</span>
          <strong>{feeEnabledRead.data ? t('yes') : t('no')}</strong>
        </div>
        <div>
          <span>{t('feeBps')}</span>
          <strong>{feeBpsRead.data ? feeBpsRead.data.toString() : '0'}</strong>
        </div>
        <div>
          <span>{t('feeRecipient')}</span>
          <strong>{shortenAddress(feeRecipientRead.data)}</strong>
        </div>
        <div>
          <span>{t('totalSupply')}</span>
          <strong>{formatTokenAmount(totalSupplyRead.data)}</strong>
        </div>
        <div>
          <span>{t('decimals')}</span>
          <strong>{decimalsRead.data?.toString() ?? '18'}</strong>
        </div>
      </div>
    </article>
  );
}

export default function App() {
  const { t, locale, setLocale } = useI18n();
  const queryClient = useQueryClient();

  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const publicClient = usePublicClient({ chainId: networkConfig.chainId });

  const { connectAsync, connectors, isPending: isConnecting } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: isSwitchingNetwork } = useSwitchChain();

  const tx = useTxExecutor({
    onMined: () => {
      void queryClient.invalidateQueries();
    },
  });

  const [formError, setFormError] = useState<string | null>(null);
  const [connectError, setConnectError] = useState<string | null>(null);
  const [connectingConnectorUid, setConnectingConnectorUid] = useState<string | null>(null);
  const [isWalletModalOpen, setIsWalletModalOpen] = useState(false);
  const [isTxModalOpen, setIsTxModalOpen] = useState(false);
  const [activeActionModal, setActiveActionModal] = useState<ActionModalType | null>(null);
  const walletModalPanelRef = useRef<HTMLElement | null>(null);
  const walletModalCloseButtonRef = useRef<HTMLButtonElement | null>(null);
  const txModalPanelRef = useRef<HTMLElement | null>(null);
  const txModalCloseButtonRef = useRef<HTMLButtonElement | null>(null);
  const actionModalPanelRef = useRef<HTMLElement | null>(null);
  const actionModalCloseButtonRef = useRef<HTMLButtonElement | null>(null);

  const [quickStakeAmount, setQuickStakeAmount] = useState('');
  const [monadStakeAmount, setMonadStakeAmount] = useState('');
  const [monadUnstakeAmount, setMonadUnstakeAmount] = useState('');

  const [unstakeAmount, setUnstakeAmount] = useState('');

  const normalizedConnectedAddress = address ? getAddress(address) : undefined;
  const addressForReads = normalizedConnectedAddress ?? zeroAddress;

  const pausedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'paused',
  });

  const rewardRateRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'rewardRatePerBlock',
  });

  const creationFeeRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'tokenCreationFee',
  });

  const totalStakedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'totalStaked',
  });

  const totalRewardWeightRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'totalRewardWeight',
  });

  const managedTokenCountRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'managedTokensLength',
  });

  const latestBlockNumber = useBlockNumber({
    watch: true,
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const ser9AllowanceRead = useReadContract({
    address: contracts.ser9Proxy,
    abi: ser9Abi,
    functionName: 'allowance',
    args: [addressForReads, contracts.stakingProxy],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const userStakedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'stakedBalance',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const userEarnedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'earned',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
      refetchInterval: 10_000,
    },
  });

  const monBalanceRead = useBalance({
    address: normalizedConnectedAddress,
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const totalMonadStakedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'totalMonadStaked',
  });

  const userMonadStakedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'monadStakedBalance',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const userMonadEarnedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'monadEarned',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
      refetchInterval: 10_000,
    },
  });

  const managedTokenCount = Number(managedTokenCountRead.data ?? 0n);

  const managedTokenReadContracts = useMemo(
    () =>
      Array.from({ length: managedTokenCount }, (_, index) => ({
        address: contracts.stakingProxy,
        abi: stakingAbi,
        functionName: 'managedTokens' as const,
        args: [BigInt(index)] as const,
      })),
    [managedTokenCount],
  );

  const managedTokenListRead = useReadContracts({
    contracts: managedTokenReadContracts,
    query: {
      enabled: managedTokenReadContracts.length > 0,
    },
  });

  const managedTokens = useMemo(() => {
    const items: Address[] = [];

    for (const result of managedTokenListRead.data ?? []) {
      if (result.status !== 'success') {
        continue;
      }

      if (typeof result.result === 'string' && isAddress(result.result)) {
        items.push(getAddress(result.result));
      }
    }

    return items;
  }, [managedTokenListRead.data]);

  const onWrongChain = isConnected && chainId !== networkConfig.chainId;

  const parsedQuickStakeAmount = useMemo(() => {
    const amount = quickStakeAmount.trim();
    if (!amount) {
      return null;
    }

    try {
      return parsePositiveTokenAmount(amount);
    } catch {
      return null;
    }
  }, [quickStakeAmount]);

  const quickStakeNeedsApproval =
    parsedQuickStakeAmount !== null && (ser9AllowanceRead.data ?? 0n) < parsedQuickStakeAmount;
  const normalizedPathname = (typeof window !== 'undefined' ? window.location.pathname : '/')
    .replace(/\/+$/, '') || '/';
  const isTokensListPage = normalizedPathname === '/tokens' || normalizedPathname === '/tokens/create';
  const isTokenCreatePage = false;
  const isHomePage = !isTokensListPage && !isTokenCreatePage;
  const hasTxActivity =
    tx.isWalletPrompt ||
    tx.isConfirming ||
    tx.isSuccess ||
    Boolean(tx.errorKey) ||
    Boolean(tx.errorDetail) ||
    Boolean(formError) ||
    Boolean(tx.txHash);

  useEffect(() => {
    if (!normalizedConnectedAddress || latestBlockNumber.data === undefined) {
      return;
    }

    void userEarnedRead.refetch();
    void userMonadEarnedRead.refetch();
  }, [latestBlockNumber.data, normalizedConnectedAddress, userEarnedRead, userMonadEarnedRead]);

  useEffect(() => {
    if (hasTxActivity) {
      setIsTxModalOpen(true);
    }
  }, [hasTxActivity]);

  useEffect(() => {
    if (!isWalletModalOpen) {
      return;
    }

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setIsWalletModalOpen(false);
        return;
      }

      if (event.key !== 'Tab') {
        return;
      }

      const panel = walletModalPanelRef.current;
      if (!panel) {
        return;
      }

      const focusable = panel.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      );

      if (focusable.length === 0) {
        return;
      }

      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement as HTMLElement | null;

      if (event.shiftKey && active === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && active === last) {
        event.preventDefault();
        first.focus();
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
    };
  }, [isWalletModalOpen]);

  useEffect(() => {
    if (!isTxModalOpen) {
      return;
    }

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setIsTxModalOpen(false);
        return;
      }

      if (event.key !== 'Tab') {
        return;
      }

      const panel = txModalPanelRef.current;
      if (!panel) {
        return;
      }

      const focusable = panel.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      );

      if (focusable.length === 0) {
        return;
      }

      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement as HTMLElement | null;

      if (event.shiftKey && active === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && active === last) {
        event.preventDefault();
        first.focus();
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
    };
  }, [isTxModalOpen]);

  useEffect(() => {
    if (!activeActionModal) {
      return;
    }

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setActiveActionModal(null);
        return;
      }

      if (event.key !== 'Tab') {
        return;
      }

      const panel = actionModalPanelRef.current;
      if (!panel) {
        return;
      }

      const focusable = panel.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      );

      if (focusable.length === 0) {
        return;
      }

      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement as HTMLElement | null;

      if (event.shiftKey && active === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && active === last) {
        event.preventDefault();
        first.focus();
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
    };
  }, [activeActionModal]);

  useEffect(() => {
    if (!isWalletModalOpen && !isTxModalOpen && !activeActionModal) {
      return;
    }

    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    if (isWalletModalOpen) {
      walletModalCloseButtonRef.current?.focus();
    } else if (activeActionModal) {
      actionModalCloseButtonRef.current?.focus();
    } else {
      txModalCloseButtonRef.current?.focus();
    }

    return () => {
      document.body.style.overflow = previousOverflow;
    };
  }, [activeActionModal, isWalletModalOpen, isTxModalOpen]);

  function mapLocalError(error: unknown): string {
    if (!(error instanceof Error)) {
      return t('unknownError');
    }

    switch (error.message) {
      case 'INVALID_ADDRESS':
        return t('invalidAddress');
      case 'INVALID_AMOUNT':
        return t('invalidAmount');
      case 'INVALID_BPS':
        return t('invalidBps');
      case 'INVALID_MAX_MULTIPLIER_BPS':
        return t('invalidMaxMultiplierBps');
      case 'INVALID_RAMP_START_BPS':
        return t('invalidRampStartBps');
      case 'INVALID_HEX':
        return t('invalidHex');
      default:
        return t('unknownError');
    }
  }

  function mapConnectError(error: unknown): string {
    if (!(error instanceof Error)) {
      return t('unknownError');
    }

    const message = error.message.toLowerCase();
    if (message.includes('user rejected')) {
      return t('walletRejected');
    }
    if (message.includes('connector not found') || message.includes('provider') || message.includes('not installed')) {
      return t('walletNotDetected');
    }

    return error.message || t('unknownError');
  }

  function resetErrors() {
    setFormError(null);
  }

  async function connectWallet(connector: (typeof connectors)[number]) {
    setConnectError(null);
    setConnectingConnectorUid(connector.uid);

    try {
      await connectAsync({ connector });
      setIsWalletModalOpen(false);
    } catch (error) {
      setConnectError(mapConnectError(error));
    } finally {
      setConnectingConnectorUid(null);
    }
  }

  async function runWrite(
    actionKey: MessageKey,
    requestFactory: () => Parameters<typeof tx.execute>[1],
    roleCheck?: () => string | null,
  ) {
    resetErrors();

    if (roleCheck) {
      const message = roleCheck();
      if (message) {
        setFormError(message);
        return;
      }
    }

    try {
      const request = requestFactory();
      return await tx.execute(t(actionKey), request);
    } catch (error) {
      setFormError(mapLocalError(error));
      return undefined;
    }
  }

  function onSubmit(event: { preventDefault: () => void }, handler: () => void) {
    event.preventDefault();
    void handler();
  }

  function renderTxStatusContent() {
    return (
      <div className="tx-feed" role="status" aria-live="polite">
        {tx.actionLabel ? (
          <p>
            {t('lastAction')}: <strong>{tx.actionLabel}</strong>
          </p>
        ) : (
          <p className="muted">-</p>
        )}

        {tx.isWalletPrompt && <p>{t('walletPrompt')}</p>}
        {tx.isConfirming && <p>{t('txPending')}</p>}
        {tx.isSuccess && <p className="success">{t('txSuccess')}</p>}
        {tx.errorKey && <p className="error">{t(tx.errorKey)}</p>}
        {tx.errorDetail && <p className="muted">{tx.errorDetail}</p>}
        {formError && <p className="error">{formError}</p>}

        {tx.txHash && (
          <p>
            {t('txHash')}:&nbsp;
            <a href={explorerTxUrl(tx.txHash)} target="_blank" rel="noreferrer">
              {shortenAddress(tx.txHash as Address, 8)}
            </a>
          </p>
        )}
      </div>
    );
  }

  async function runStakeWithAutoApprove(rawAmount: string) {
    resetErrors();

    if (!normalizedConnectedAddress) {
      setFormError(t('connectHint'));
      return undefined;
    }

    try {
      const amount = parsePositiveTokenAmount(rawAmount);
      const allowance = ser9AllowanceRead.data ?? 0n;

      if (allowance < amount) {
        const approveHash = await tx.execute(t('ser9Approve'), {
          address: contracts.ser9Proxy,
          abi: ser9Abi,
          functionName: 'approve',
          args: [contracts.stakingProxy, maxUint256],
        });

        if (!approveHash) {
          return undefined;
        }
      }

      return await tx.execute(t('stake'), {
        address: contracts.stakingProxy,
        abi: stakingAbi,
        functionName: 'stake',
        args: [amount],
      });
    } catch (error) {
      setFormError(mapLocalError(error));
      return undefined;
    }
  }

  async function runMonadStakeFlow() {
    resetErrors();

    try {
      const request = {
        to: contracts.stakingProxy,
        value: parsePositiveTokenAmount(monadStakeAmount),
        data: encodeFunctionData({
          abi: stakingAbi,
          functionName: 'stakeMonad',
          args: [],
        }),
      };

      if (publicClient && address) {
        const optimizedRequest = await (async () => {
          const feeEstimate = await publicClient.estimateFeesPerGas();
          const feeOverrides = 'gasPrice' in feeEstimate
            ? { gasPrice: feeEstimate.gasPrice }
            : {
                maxFeePerGas: feeEstimate.maxFeePerGas,
                maxPriorityFeePerGas: feeEstimate.maxPriorityFeePerGas,
              };
          const estimatedGas = await publicClient.estimateGas({
            account: address,
            ...request,
            ...feeOverrides,
          });

          return {
            ...request,
            ...feeOverrides,
            gas: (estimatedGas * 110n) / 100n,
          };
        })().catch(() => request);

        return await tx.executeSend(t('monadStake'), optimizedRequest);
      }

      return await tx.executeSend(t('monadStake'), request);
    } catch (error) {
      setFormError(mapLocalError(error));
      return undefined;
    }
  }

  async function submitActionModal() {
    if (!activeActionModal) {
      return;
    }

    if (activeActionModal === 'ser9Stake') {
      const hash = await runStakeWithAutoApprove(quickStakeAmount);
      if (hash) {
        setActiveActionModal(null);
      }
      return;
    }

    if (activeActionModal === 'ser9Unstake') {
      const hash = await runWrite('unstake', () => ({
        address: contracts.stakingProxy,
        abi: stakingAbi,
        functionName: 'unstake',
        args: [parsePositiveTokenAmount(unstakeAmount)],
      }));
      if (hash) {
        setActiveActionModal(null);
      }
      return;
    }

    if (activeActionModal === 'monadStake') {
      const hash = await runMonadStakeFlow();
      if (hash) {
        setActiveActionModal(null);
      }
      return;
    }

    const hash = await runWrite('requestMonadUnstake', () => ({
      address: contracts.stakingProxy,
      abi: stakingAbi,
      functionName: 'requestUnstakeMonad' as const,
      args: [parsePositiveTokenAmount(monadUnstakeAmount)] as const,
    }));
    if (hash) {
      setActiveActionModal(null);
    }
  }

  function getActionModalTitle(action: ActionModalType) {
    switch (action) {
      case 'ser9Stake':
        return t('stake');
      case 'ser9Unstake':
        return t('unstake');
      case 'monadStake':
        return t('monadStake');
      case 'monadUnstake':
        return t('requestMonadUnstake');
    }
  }

  function renderActionModalForm() {
    if (!activeActionModal) {
      return null;
    }

    if (activeActionModal === 'ser9Stake') {
      return (
        <form className="single-form" onSubmit={(event) => onSubmit(event, submitActionModal)}>
          <input value={quickStakeAmount} onChange={(event) => setQuickStakeAmount(event.target.value)} placeholder={t('amount')} />
          {isConnected ? (
            <p className="muted">
              {t('currentAllowance')}: {formatTokenAmount(ser9AllowanceRead.data)}
            </p>
          ) : (
            <p className="muted">{t('connectHint')}</p>
          )}
          <button type="submit" className="primary" disabled={!isConnected || onWrongChain}>
            {quickStakeNeedsApproval ? t('approveAndStake') : t('stake')}
          </button>
        </form>
      );
    }

    if (activeActionModal === 'ser9Unstake') {
      return (
        <form className="single-form" onSubmit={(event) => onSubmit(event, submitActionModal)}>
          <input value={unstakeAmount} onChange={(event) => setUnstakeAmount(event.target.value)} placeholder={t('amount')} />
          <button type="submit" className="primary" disabled={!isConnected || onWrongChain}>
            {t('unstake')}
          </button>
        </form>
      );
    }

    if (activeActionModal === 'monadStake') {
      return (
        <form className="single-form" onSubmit={(event) => onSubmit(event, submitActionModal)}>
          <input value={monadStakeAmount} onChange={(event) => setMonadStakeAmount(event.target.value)} placeholder={t('amount')} />
          <button type="submit" className="primary" disabled={!isConnected || onWrongChain}>
            {t('monadStake')}
          </button>
        </form>
      );
    }

    return (
      <form className="single-form" onSubmit={(event) => onSubmit(event, submitActionModal)}>
        <input value={monadUnstakeAmount} onChange={(event) => setMonadUnstakeAmount(event.target.value)} placeholder={t('amount')} />
        <button type="submit" className="primary" disabled={!isConnected || onWrongChain}>
          {t('requestMonadUnstake')}
        </button>
      </form>
    );
  }

  return (
    <div className="app-shell">
      <header className="hero">
        <div className="hero-copy">
          <div className="hero-topline">
            <nav className="page-nav">
              <a href="/" className={normalizedPathname === '/' ? 'active' : ''}>
                {t('navHome')}
              </a>
              <a href="/tokens" className={isTokensListPage ? 'active' : ''}>
                {t('navTokens')}
              </a>
            </nav>
            <div className="section-title hero-kicker">{t('stakingOverview')}</div>
          </div>
          <div className="hero-copy-block">
            <h1>{t('appTitle')}</h1>
            <p className="hero-description">{t('appSubtitle')}</p>
          </div>
          <div className="hero-badges">
            <span className="hero-badge">
              {t('targetChain')}: {networkConfig.chainId}
            </span>
            <span className="hero-badge">
              {t('managedTokenCount')}: {String(managedTokenCount)}
            </span>
            <span className={`hero-badge ${pausedRead.data ? 'is-paused' : 'is-live'}`}>
              {t('paused')}: {pausedRead.data === undefined ? '-' : pausedRead.data ? t('yes') : t('no')}
            </span>
          </div>
        </div>

        <div className="header-actions hero-panel">
          <div className="lang-switch">
            <span>{t('languageLabel')}</span>
            <button
              type="button"
              className={locale === 'ko' ? 'active' : ''}
              onClick={() => setLocale('ko')}
            >
              {t('korean')}
            </button>
            <button
              type="button"
              className={locale === 'en' ? 'active' : ''}
              onClick={() => setLocale('en')}
            >
              {t('english')}
            </button>
          </div>

          <div className="hero-account-card">
            <span>{t('account')}</span>
            <strong>{normalizedConnectedAddress ? shortenAddress(normalizedConnectedAddress, 6) : '-'}</strong>
            <small>{isConnected ? `${t('networkLabel')}: ${chainId}` : t('connectHint')}</small>
          </div>

          {!isConnected ? (
            <div className="wallet-connectors">
              {connectors.length === 0 ? (
                <p className="muted">{t('walletNotDetected')}</p>
              ) : (
                <button
                  type="button"
                  className="primary"
                  disabled={isConnecting}
                  onClick={() => {
                    setConnectError(null);
                    setIsWalletModalOpen(true);
                  }}
                >
                  {isConnecting ? t('connectPending') : t('connectWallet')}
                </button>
              )}
              {connectError && <p className="error">{connectError}</p>}
            </div>
          ) : (
            <button type="button" className="secondary" onClick={() => disconnect()}>
              {t('disconnectWallet')}
            </button>
          )}
        </div>
      </header>

      <section className="connection-summary card">
        <div className="summary-tile">
          <span>{t('account')}</span>
          <strong>{normalizedConnectedAddress ? shortenAddress(normalizedConnectedAddress, 6) : '-'}</strong>
        </div>
        <div className="summary-tile">
          <span>{t('networkLabel')}</span>
          <strong>{isConnected ? chainId : '-'}</strong>
        </div>
        <div className="summary-tile summary-tile-accent">
          <span>{t('targetChain')}</span>
          <strong>{networkConfig.chainId}</strong>
        </div>
        <div className="summary-tile summary-tile-action">
          <button type="button" className="secondary" onClick={() => void queryClient.invalidateQueries()}>
            {t('refresh')}
          </button>
        </div>
      </section>

      {onWrongChain && (
        <section className="warning card">
          <h3>{t('wrongNetworkTitle')}</h3>
          <p>{t('wrongNetworkBody')}</p>
          <button
            type="button"
            className="primary"
            disabled={!switchChain || isSwitchingNetwork}
            onClick={() => switchChain?.({ chainId: networkConfig.chainId })}
          >
            {isSwitchingNetwork ? t('switchPending') : t('switchNetwork')}
          </button>
        </section>
      )}

      {isTokensListPage && (
        <>
          <section className="card">
            <div className="section-head section-head-highlight">
              <div>
                <div className="section-title section-title-inline">{t('sectionManagedTokens')}</div>
                <h2>{t('tokensPageTitle')}</h2>
              </div>
            </div>
            <p className="muted">{t('tokensPageHint')}</p>
          </section>

          <section className="card">
            <div className="section-head section-head-highlight">
              <div>
                <div className="section-title section-title-inline">{t('stakingOverview')}</div>
                <h2>{t('stakingOverview')}</h2>
              </div>
            </div>
            <div className="section-title">{t('protocolState')}</div>
            <div className="metric-grid">
              <MetricCard
                label={t('paused')}
                value={pausedRead.data === undefined ? '-' : pausedRead.data ? t('yes') : t('no')}
              />
              <MetricCard label={t('totalStaked')} value={formatTokenAmount(totalStakedRead.data)} />
              <MetricCard label={t('totalRewardWeight')} value={formatTokenAmount(totalRewardWeightRead.data)} />
              <MetricCard label={t('rewardRatePerBlock')} value={formatTokenAmount(rewardRateRead.data)} />
              <MetricCard label={t('tokenCreationFee')} value={formatTokenAmount(creationFeeRead.data)} />
              <MetricCard label={t('managedTokenCount')} value={String(managedTokenCount)} />
            </div>
          </section>

          <section className="card">
            <div className="section-head section-head-highlight">
              <div>
                <div className="section-title section-title-inline">SER9</div>
                <h2>{t('quickStakeSection')}</h2>
              </div>
            </div>
            <p className="muted">{t('quickStakeHint')}</p>
            <button type="button" className="primary" disabled={!isConnected || onWrongChain} onClick={() => setActiveActionModal('ser9Stake')}>
              {quickStakeNeedsApproval ? t('approveAndStake') : t('stake')}
            </button>
            {isConnected ? (
              <p className="muted">
                {t('currentAllowance')}: {formatTokenAmount(ser9AllowanceRead.data)}
              </p>
            ) : (
              <p className="muted">{t('connectHint')}</p>
            )}
          </section>
        </>
      )}

      {isHomePage && (
        <>
          <div className="section-title section-title-top">{t('userState')}</div>
          <section className="summary-grid">
            <article className="status-card">
              <div className="status-card-head">
                <div>
                  <div className="section-title section-title-inline">SER9</div>
                  <h2>{t('ser9StakingStatus')}</h2>
                </div>
                <span className="pill">SER9</span>
              </div>
              <p className="status-card-copy muted">{t('quickStakeHint')}</p>
              <div className="metric-grid">
                <MetricCard label={t('totalStaked')} value={formatTokenAmount(totalStakedRead.data)} />
                <MetricCard label={t('stakedBalance')} value={formatTokenAmount(userStakedRead.data)} />
                <MetricCard label={t('earnedRewards')} value={formatRewardAmount(userEarnedRead.data)} />
              </div>
              <div className="status-actions">
                <button type="button" onClick={() => setActiveActionModal('ser9Stake')} disabled={!isConnected || onWrongChain}>
                  {t('stake')}
                </button>

                <button type="button" onClick={() => setActiveActionModal('ser9Unstake')} disabled={!isConnected || onWrongChain}>
                  {t('unstake')}
                </button>

                <button
                  type="button"
                  onClick={(event) => onSubmit(event, () => runWrite('claimRewards', () => ({
                    address: contracts.stakingProxy,
                    abi: stakingAbi,
                    functionName: 'claimRewards',
                    args: [],
                  })))}
                  disabled={!isConnected || onWrongChain}
                >
                  {t('claimRewards')}
                </button>
              </div>
            </article>

            <article className="status-card">
              <div className="status-card-head">
                <div>
                  <div className="section-title section-title-inline">MONAD</div>
                  <h2>{t('monadStakingStatus')}</h2>
                </div>
                <span className="pill">MON</span>
              </div>
              <p className="status-card-copy muted">{t('monadStakingDescription')}</p>
              <div className="metric-grid">
                <MetricCard label={t('totalMonadStaked')} value={formatTokenAmount(totalMonadStakedRead.data)} />
                <MetricCard label={t('yourMonadStake')} value={formatTokenAmount(userMonadStakedRead.data)} />
                <MetricCard label={t('monBalance')} value={formatTokenAmount(monBalanceRead.data?.value)} />
                <MetricCard label={t('yourMonadSer9Rewards')} value={formatRewardAmount(userMonadEarnedRead.data)} />
              </div>
              <div className="status-actions">
                <button type="button" onClick={() => setActiveActionModal('monadStake')} disabled={!isConnected || onWrongChain}>
                  {t('monadStake')}
                </button>

                <button type="button" onClick={() => setActiveActionModal('monadUnstake')} disabled={!isConnected || onWrongChain}>
                  {t('requestMonadUnstake')}
                </button>

                <button
                  type="button"
                  onClick={(event) => onSubmit(event, () => runWrite('claimSer9Rewards', () => ({
                    address: contracts.stakingProxy,
                    abi: stakingAbi,
                    functionName: 'claimRewards' as const,
                    args: [] as const,
                  })))}
                  disabled={!isConnected || onWrongChain}
                >
                  {t('claimSer9Rewards')}
                </button>
              </div>
            </article>
          </section>

        </>
      )}

      {!isHomePage && (
        <section className="card">
          <div className="section-head section-head-highlight">
            <div>
              <div className="section-title section-title-inline">{t('sectionManagedTokens')}</div>
              <h2>{t('sectionManagedTokens')}</h2>
            </div>
          </div>
          {managedTokens.length === 0 ? (
            <p className="muted">{t('noManagedTokens')}</p>
          ) : (
            <div className="token-list">
              {managedTokens.map((token) => (
                <ManagedTokenCard key={token} token={token} />
              ))}
            </div>
          )}
        </section>
      )}

      {activeActionModal && (
        <div className="modal-backdrop">
          <section
            className="modal-panel"
            role="dialog"
            aria-modal="true"
            aria-label={getActionModalTitle(activeActionModal)}
            ref={actionModalPanelRef}
            tabIndex={-1}
          >
            <div className="tx-header">
              <h2>{getActionModalTitle(activeActionModal)}</h2>
              <button
                ref={actionModalCloseButtonRef}
                type="button"
                className="secondary"
                onClick={() => setActiveActionModal(null)}
              >
                {t('close')}
              </button>
            </div>
            {renderActionModalForm()}
          </section>
        </div>
      )}

      {isTxModalOpen && (
        <div className="modal-backdrop">
          <section
            className="modal-panel"
            role="dialog"
            aria-modal="true"
            aria-label={t('txStatus')}
            ref={txModalPanelRef}
            tabIndex={-1}
          >
            <div className="tx-header">
              <h2>{t('txStatus')}</h2>
              <button
                ref={txModalCloseButtonRef}
                type="button"
                className="secondary"
                onClick={() => setIsTxModalOpen(false)}
              >
                {t('close')}
              </button>
            </div>
            {renderTxStatusContent()}
          </section>
        </div>
      )}

      {isWalletModalOpen && !isConnected && (
        <div className="modal-backdrop">
          <section
            className="modal-panel"
            role="dialog"
            aria-modal="true"
            aria-label={t('walletConnectTitle')}
            ref={walletModalPanelRef}
            tabIndex={-1}
          >
            <div className="tx-header">
              <h2>{t('walletConnectTitle')}</h2>
              <button
                ref={walletModalCloseButtonRef}
                type="button"
                className="secondary"
                onClick={() => setIsWalletModalOpen(false)}
              >
                {t('close')}
              </button>
            </div>
            <p className="muted">{t('walletConnectDescription')}</p>
            <div className="wallet-connectors">
              {connectors.map((connector) => {
                const isCurrent = isConnecting && connectingConnectorUid === connector.uid;
                return (
                  <button
                    key={connector.uid}
                    type="button"
                    className="primary"
                    disabled={isConnecting}
                    onClick={() => void connectWallet(connector)}
                  >
                    {isCurrent ? t('connectPending') : `${t('connectWallet')} · ${connector.name}`}
                  </button>
                );
              })}
            </div>
            {connectError && <p className="error">{connectError}</p>}
          </section>
        </div>
      )}
    </div>
  );
}
