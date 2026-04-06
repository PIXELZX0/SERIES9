import { useQueryClient } from '@tanstack/react-query';
import { useMemo, useState, type FormEvent } from 'react';
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  useReadContract,
  useReadContracts,
  useSwitchChain,
} from 'wagmi';
import { getAddress, isAddress, maxUint256, zeroAddress, type Address } from 'viem';

import { explorerTxUrl, networkConfig } from './config/chain';
import { contracts } from './config/contracts';
import { managedTokenAbi, ser9Abi, stakingAbi } from './contracts/abi';
import { useTxExecutor } from './hooks/useTxExecutor';
import { useI18n, type MessageKey } from './i18n';
import { equalsAddress, formatTokenAmount, shortenAddress } from './utils/format';
import {
  parseAddressStrict,
  parseMaxMultiplierBps,
  parseNonNegativeBps,
  parseOptionalTokenAmountOrZero,
  parsePositiveTokenAmount,
  parseRampStartBps,
} from './utils/validation';

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

function ManagedTokenCard({
  token,
  userAddress,
}: {
  token: Address;
  userAddress: Address | undefined;
}) {
  const { t } = useI18n();
  const scopedUser = userAddress ?? zeroAddress;

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

  const userBalanceRead = useReadContract({
    address: token,
    abi: managedTokenAbi,
    functionName: 'balanceOf',
    args: [scopedUser],
    query: {
      enabled: Boolean(userAddress),
    },
  });

  const feeStakeRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'feeStakeBalance',
    args: [token, scopedUser],
    query: {
      enabled: Boolean(userAddress),
    },
  });

  const pendingFeeRewardRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'pendingFeeRewards',
    args: [token, scopedUser],
    query: {
      enabled: Boolean(userAddress),
    },
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
          <span>{t('creator')}</span>
          <strong>{shortenAddress(tokenConfig?.creator)}</strong>
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
        <div>
          <span>{t('yourTokenBalance')}</span>
          <strong>{formatTokenAmount(userBalanceRead.data)}</strong>
        </div>
        <div>
          <span>{t('yourFeeStake')}</span>
          <strong>{formatTokenAmount(feeStakeRead.data)}</strong>
        </div>
        <div>
          <span>{t('yourPendingFeeRewards')}</span>
          <strong>{formatTokenAmount(pendingFeeRewardRead.data)}</strong>
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

  const [ser9ApproveAmount, setSer9ApproveAmount] = useState('');
  const [ser9ApproveSpender, setSer9ApproveSpender] = useState<string>(contracts.stakingProxy);

  const [managedApproveToken, setManagedApproveToken] = useState('');
  const [managedApproveAmount, setManagedApproveAmount] = useState('');
  const [managedApproveSpender, setManagedApproveSpender] = useState<string>(contracts.stakingProxy);

  const [quickStakeAmount, setQuickStakeAmount] = useState('');

  const [stakeAmount, setStakeAmount] = useState('');
  const [unstakeAmount, setUnstakeAmount] = useState('');

  const [createName, setCreateName] = useState('');
  const [createSymbol, setCreateSymbol] = useState('');
  const [createMintRate, setCreateMintRate] = useState('');
  const [createMaxSupply, setCreateMaxSupply] = useState('');
  const [createMaxMultiplierBps, setCreateMaxMultiplierBps] = useState('10000');
  const [createRampStartBps, setCreateRampStartBps] = useState('0');
  const [createFeeEnabled, setCreateFeeEnabled] = useState(false);
  const [createFeeBps, setCreateFeeBps] = useState('0');

  const [mintToken, setMintToken] = useState('');
  const [mintAmount, setMintAmount] = useState('');

  const [burnToken, setBurnToken] = useState('');
  const [burnAmount, setBurnAmount] = useState('');

  const [feeStakeToken, setFeeStakeToken] = useState('');
  const [feeStakeAmount, setFeeStakeAmount] = useState('');

  const [feeUnstakeToken, setFeeUnstakeToken] = useState('');
  const [feeUnstakeAmount, setFeeUnstakeAmount] = useState('');

  const [feeClaimToken, setFeeClaimToken] = useState('');

  const [creatorToken, setCreatorToken] = useState('');
  const [creatorFeeBps, setCreatorFeeBps] = useState('');

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

  const ser9BalanceRead = useReadContract({
    address: contracts.ser9Proxy,
    abi: ser9Abi,
    functionName: 'balanceOf',
    args: [addressForReads],
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

  const userLockedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'lockedBalance',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const userUnlockedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'unlockedStake',
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
    },
  });

  const userUnusedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'availableUnusedLocked',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const userUsedRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'usedLockedSer9',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
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

  const creatorTokenAddress = isAddress(creatorToken) ? getAddress(creatorToken) : undefined;
  const mintTokenAddress = isAddress(mintToken) ? getAddress(mintToken) : undefined;

  const creatorTokenConfigRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'tokenConfigs',
    args: creatorTokenAddress ? [creatorTokenAddress] : undefined,
    query: {
      enabled: Boolean(creatorTokenAddress),
    },
  });

  const creatorTokenConfig = parseTokenConfig(creatorTokenConfigRead.data);
  const connectedIsCreator = equalsAddress(creatorTokenConfig?.creator, normalizedConnectedAddress);

  const onWrongChain = isConnected && chainId !== networkConfig.chainId;

  const datalistTokens = useMemo(() => {
    return managedTokens.map((token) => token.toLowerCase());
  }, [managedTokens]);

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

  const parsedMintAmount = useMemo(() => {
    const amount = mintAmount.trim();
    if (!amount) {
      return null;
    }

    try {
      return parsePositiveTokenAmount(amount);
    } catch {
      return null;
    }
  }, [mintAmount]);

  const previewMintCollateralRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'previewMintCollateral',
    args:
      mintTokenAddress && parsedMintAmount !== null
        ? [mintTokenAddress, parsedMintAmount]
        : undefined,
    query: {
      enabled: Boolean(mintTokenAddress && parsedMintAmount !== null),
    },
  });

  const quickStakeNeedsApproval =
    parsedQuickStakeAmount !== null && (ser9AllowanceRead.data ?? 0n) < parsedQuickStakeAmount;
  const normalizedPathname = (typeof window !== 'undefined' ? window.location.pathname : '/')
    .replace(/\/+$/, '') || '/';
  const isTokensListPage = normalizedPathname === '/tokens';
  const isTokenCreatePage = normalizedPathname === '/tokens/create';
  const isHomePage = !isTokensListPage && !isTokenCreatePage;

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
      await tx.execute(t(actionKey), request);
    } catch (error) {
      setFormError(mapLocalError(error));
    }
  }

  function onSubmit(event: FormEvent<HTMLFormElement>, handler: () => void) {
    event.preventDefault();
    void handler();
  }

  function createManagedTokenRequest() {
    const name = createName.trim();
    const symbol = createSymbol.trim();

    if (!name || !symbol) {
      throw new Error('INVALID_AMOUNT');
    }

    return {
      address: contracts.stakingProxy,
      abi: stakingAbi,
      functionName: 'createManagedTokenWithPolicy' as const,
      args: [
        name,
        symbol,
        parsePositiveTokenAmount(createMintRate),
        createFeeEnabled,
        createFeeEnabled ? parseNonNegativeBps(createFeeBps) : 0,
        parseOptionalTokenAmountOrZero(createMaxSupply),
        parseMaxMultiplierBps(createMaxMultiplierBps),
        parseRampStartBps(createRampStartBps),
      ] as const,
    };
  }

  async function runQuickStakeFlow() {
    await runStakeWithAutoApprove(quickStakeAmount);
  }

  async function runStakeWithAutoApprove(rawAmount: string) {
    resetErrors();

    if (!normalizedConnectedAddress) {
      setFormError(t('connectHint'));
      return;
    }

    try {
      const amount = parsePositiveTokenAmount(rawAmount);
      const allowance = ser9AllowanceRead.data ?? 0n;

      if (allowance < amount) {
        await tx.execute(t('ser9Approve'), {
          address: contracts.ser9Proxy,
          abi: ser9Abi,
          functionName: 'approve',
          args: [contracts.stakingProxy, maxUint256],
        });
      }

      await tx.execute(t('stake'), {
        address: contracts.stakingProxy,
        abi: stakingAbi,
        functionName: 'stake',
        args: [amount],
      });
    } catch (error) {
      setFormError(mapLocalError(error));
    }
  }

  return (
    <div className="app-shell">
      <header className="hero">
        <div>
          <nav className="page-nav">
            <a href="/" className={normalizedPathname === '/' ? 'active' : ''}>
              {t('navHome')}
            </a>
            <a href="/tokens" className={isTokensListPage ? 'active' : ''}>
              {t('navTokens')}
            </a>
            <a href="/tokens/create" className={isTokenCreatePage ? 'active' : ''}>
              {t('navCreateToken')}
            </a>
          </nav>
          <h1>{t('appTitle')}</h1>
          <p>{t('appSubtitle')}</p>
        </div>

        <div className="header-actions">
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

          {!isConnected ? (
            <div className="wallet-connectors">
              {connectors.length === 0 ? (
                <p className="muted">{t('walletNotDetected')}</p>
              ) : (
                connectors.map((connector) => {
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
                })
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
        <div>
          <span>{t('account')}</span>
          <strong>{normalizedConnectedAddress ? shortenAddress(normalizedConnectedAddress, 6) : '-'}</strong>
        </div>
        <div>
          <span>{t('networkLabel')}</span>
          <strong>{isConnected ? chainId : '-'}</strong>
        </div>
        <div>
          <span>{t('targetChain')}</span>
          <strong>{networkConfig.chainId}</strong>
        </div>
        <div>
          <span>Role</span>
          <strong>{connectedIsCreator ? t('roleCreator') : t('roleUser')}</strong>
        </div>
        <div>
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
            <h2>{t('tokensPageTitle')}</h2>
            <p className="muted">{t('tokensPageHint')}</p>
          </section>

          <section className="card">
            <h2>{t('stakingOverview')}</h2>
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
            <h2>{t('quickStakeSection')}</h2>
            <p className="muted">{t('quickStakeHint')}</p>
            <form className="single-form" onSubmit={(event) => onSubmit(event, runQuickStakeFlow)}>
              <input
                value={quickStakeAmount}
                onChange={(event) => setQuickStakeAmount(event.target.value)}
                placeholder={t('amount')}
              />
              <button type="submit" disabled={!isConnected || onWrongChain}>
                {quickStakeNeedsApproval ? t('approveAndStake') : t('stake')}
              </button>
            </form>
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

      {isTokenCreatePage && (
        <section className="card">
          <h2>{t('tokensCreatePageTitle')}</h2>
          <p className="muted">{t('tokensCreatePageHint')}</p>
          <form
            className="single-form"
            onSubmit={(event) => onSubmit(event, () => runWrite('createManagedToken', createManagedTokenRequest))}
          >
            <input value={createName} onChange={(e) => setCreateName(e.target.value)} placeholder={t('tokenName')} />
            <input value={createSymbol} onChange={(e) => setCreateSymbol(e.target.value)} placeholder={t('tokenSymbol')} />
            <input value={createMintRate} onChange={(e) => setCreateMintRate(e.target.value)} placeholder={t('mintRatePerToken')} />
            <input value={createMaxSupply} onChange={(e) => setCreateMaxSupply(e.target.value)} placeholder={t('maxSupplyOptional')} />
            <input
              value={createMaxMultiplierBps}
              onChange={(e) => setCreateMaxMultiplierBps(e.target.value)}
              placeholder={t('maxMultiplierBpsInput')}
            />
            <input
              value={createRampStartBps}
              onChange={(e) => setCreateRampStartBps(e.target.value)}
              placeholder={t('rampStartBpsInput')}
            />
            <label className="checkbox-row">
              <input type="checkbox" checked={createFeeEnabled} onChange={(e) => setCreateFeeEnabled(e.target.checked)} />
              {t('enableFee')}
            </label>
            <input
              value={createFeeBps}
              onChange={(e) => setCreateFeeBps(e.target.value)}
              placeholder={t('initialFeeBps')}
              disabled={!createFeeEnabled}
            />
            <button type="submit" disabled={!isConnected || onWrongChain}>
              {t('createManagedToken')}
            </button>
          </form>
        </section>
      )}

      {isHomePage && (
        <>
          <section className="card">
            <h2>{t('userState')}</h2>
            {isConnected ? (
              <>
                <div className="metric-grid">
                  <MetricCard label={t('ser9Balance')} value={formatTokenAmount(ser9BalanceRead.data)} />
                  <MetricCard label={t('stakedBalance')} value={formatTokenAmount(userStakedRead.data)} />
                  <MetricCard label={t('lockedBalance')} value={formatTokenAmount(userLockedRead.data)} />
                  <MetricCard label={t('unlockedBalance')} value={formatTokenAmount(userUnlockedRead.data)} />
                  <MetricCard label={t('earnedRewards')} value={formatTokenAmount(userEarnedRead.data)} />
                  <MetricCard label={t('unusedLocked')} value={formatTokenAmount(userUnusedRead.data)} />
                  <MetricCard label={t('usedLocked')} value={formatTokenAmount(userUsedRead.data)} />
                </div>
              </>
            ) : (
              <p className="muted">{t('connectHint')}</p>
            )}
          </section>
        </>
      )}

      {!isHomePage && (
        <section className="card">
          <h2>{t('sectionManagedTokens')}</h2>
          {managedTokens.length === 0 ? (
            <p className="muted">{t('noManagedTokens')}</p>
          ) : (
            <div className="token-list">
              {managedTokens.map((token) => (
                <ManagedTokenCard key={token} token={token} userAddress={normalizedConnectedAddress} />
              ))}
            </div>
          )}
        </section>
      )}

      {(isTokensListPage || isHomePage) && (
        <>
          <section className="card">
            <h2>{t('userActions')}</h2>
            <div className="action-grid">
          <form onSubmit={(event) => onSubmit(event, () => runWrite('ser9Approve', () => ({
            address: contracts.ser9Proxy,
            abi: ser9Abi,
            functionName: 'approve',
            args: [parseAddressStrict(ser9ApproveSpender), parsePositiveTokenAmount(ser9ApproveAmount)],
          })))}>
            <h3>{t('ser9Approve')}</h3>
            <input value={ser9ApproveSpender} onChange={(e) => setSer9ApproveSpender(e.target.value)} placeholder={t('spender')} />
            <input value={ser9ApproveAmount} onChange={(e) => setSer9ApproveAmount(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('approve')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite('managedApprove', () => ({
            address: parseAddressStrict(managedApproveToken),
            abi: managedTokenAbi,
            functionName: 'approve',
            args: [parseAddressStrict(managedApproveSpender), parsePositiveTokenAmount(managedApproveAmount)],
          })))}>
            <h3>{t('managedApprove')}</h3>
            <input list="managed-token-list" value={managedApproveToken} onChange={(e) => setManagedApproveToken(e.target.value)} placeholder={t('tokenAddress')} />
            <input value={managedApproveSpender} onChange={(e) => setManagedApproveSpender(e.target.value)} placeholder={t('spender')} />
            <input value={managedApproveAmount} onChange={(e) => setManagedApproveAmount(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('approve')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runStakeWithAutoApprove(stakeAmount))}>
            <h3>{t('stake')}</h3>
            <input value={stakeAmount} onChange={(e) => setStakeAmount(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('stake')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite('unstake', () => ({
            address: contracts.stakingProxy,
            abi: stakingAbi,
            functionName: 'unstake',
            args: [parsePositiveTokenAmount(unstakeAmount)],
          })))}>
            <h3>{t('unstake')}</h3>
            <input value={unstakeAmount} onChange={(e) => setUnstakeAmount(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('unstake')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite('claimRewards', () => ({
            address: contracts.stakingProxy,
            abi: stakingAbi,
            functionName: 'claimRewards',
            args: [],
          })))}>
            <h3>{t('claimRewards')}</h3>
            <button type="submit">{t('claimRewards')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite('createManagedToken', createManagedTokenRequest))}>
            <h3>{t('createManagedToken')}</h3>
            <input value={createName} onChange={(e) => setCreateName(e.target.value)} placeholder={t('tokenName')} />
            <input value={createSymbol} onChange={(e) => setCreateSymbol(e.target.value)} placeholder={t('tokenSymbol')} />
            <input value={createMintRate} onChange={(e) => setCreateMintRate(e.target.value)} placeholder={t('mintRatePerToken')} />
            <input value={createMaxSupply} onChange={(e) => setCreateMaxSupply(e.target.value)} placeholder={t('maxSupplyOptional')} />
            <input
              value={createMaxMultiplierBps}
              onChange={(e) => setCreateMaxMultiplierBps(e.target.value)}
              placeholder={t('maxMultiplierBpsInput')}
            />
            <input
              value={createRampStartBps}
              onChange={(e) => setCreateRampStartBps(e.target.value)}
              placeholder={t('rampStartBpsInput')}
            />
            <label className="checkbox-row">
              <input type="checkbox" checked={createFeeEnabled} onChange={(e) => setCreateFeeEnabled(e.target.checked)} />
              {t('enableFee')}
            </label>
            <input value={createFeeBps} onChange={(e) => setCreateFeeBps(e.target.value)} placeholder={t('initialFeeBps')} disabled={!createFeeEnabled} />
            <button type="submit">{t('createManagedToken')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite('mintManagedToken', () => ({
            address: contracts.stakingProxy,
            abi: stakingAbi,
            functionName: 'mintManagedToken',
            args: [parseAddressStrict(mintToken), parsePositiveTokenAmount(mintAmount)],
          })))}>
            <h3>{t('mintManagedToken')}</h3>
            <input list="managed-token-list" value={mintToken} onChange={(e) => setMintToken(e.target.value)} placeholder={t('tokenAddress')} />
            <input value={mintAmount} onChange={(e) => setMintAmount(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('mintManagedToken')}</button>
            {mintTokenAddress && parsedMintAmount !== null && (
              <p className="muted">
                {t('previewMintCollateral')}: {formatTokenAmount(previewMintCollateralRead.data)}
              </p>
            )}
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite('burnAndUnlock', () => ({
            address: contracts.stakingProxy,
            abi: stakingAbi,
            functionName: 'burnAndUnlock',
            args: [parseAddressStrict(burnToken), parsePositiveTokenAmount(burnAmount)],
          })))}>
            <h3>{t('burnAndUnlock')}</h3>
            <input list="managed-token-list" value={burnToken} onChange={(e) => setBurnToken(e.target.value)} placeholder={t('tokenAddress')} />
            <input value={burnAmount} onChange={(e) => setBurnAmount(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('burnAndUnlock')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite('stakeFeeToken', () => ({
            address: contracts.stakingProxy,
            abi: stakingAbi,
            functionName: 'stakeFeeToken',
            args: [parseAddressStrict(feeStakeToken), parsePositiveTokenAmount(feeStakeAmount)],
          })))}>
            <h3>{t('stakeFeeToken')}</h3>
            <input list="managed-token-list" value={feeStakeToken} onChange={(e) => setFeeStakeToken(e.target.value)} placeholder={t('tokenAddress')} />
            <input value={feeStakeAmount} onChange={(e) => setFeeStakeAmount(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('stakeFeeToken')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite('unstakeFeeToken', () => ({
            address: contracts.stakingProxy,
            abi: stakingAbi,
            functionName: 'unstakeFeeToken',
            args: [parseAddressStrict(feeUnstakeToken), parsePositiveTokenAmount(feeUnstakeAmount)],
          })))}>
            <h3>{t('unstakeFeeToken')}</h3>
            <input list="managed-token-list" value={feeUnstakeToken} onChange={(e) => setFeeUnstakeToken(e.target.value)} placeholder={t('tokenAddress')} />
            <input value={feeUnstakeAmount} onChange={(e) => setFeeUnstakeAmount(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('unstakeFeeToken')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite('claimFeeRewards', () => ({
            address: contracts.stakingProxy,
            abi: stakingAbi,
            functionName: 'claimFeeRewards',
            args: [parseAddressStrict(feeClaimToken)],
          })))}>
            <h3>{t('claimFeeRewards')}</h3>
            <input list="managed-token-list" value={feeClaimToken} onChange={(e) => setFeeClaimToken(e.target.value)} placeholder={t('tokenAddress')} />
            <button type="submit">{t('claimFeeRewards')}</button>
          </form>
            </div>
          </section>

          <section className="card">
            <h2>{t('creatorControls')}</h2>
            <form
              className="single-form"
              onSubmit={(event) => onSubmit(event, () => runWrite(
                'setTokenFeeBps',
                () => ({
                  address: contracts.stakingProxy,
                  abi: stakingAbi,
                  functionName: 'setTokenFeeBps',
                  args: [parseAddressStrict(creatorToken), parseNonNegativeBps(creatorFeeBps)],
                }),
                () => (connectedIsCreator ? null : t('creatorOnly')),
              ))}
            >
              <input list="managed-token-list" value={creatorToken} onChange={(e) => setCreatorToken(e.target.value)} placeholder={t('selectedToken')} />
              <input value={creatorFeeBps} onChange={(e) => setCreatorFeeBps(e.target.value)} placeholder={t('feeBps')} />
              <button type="submit">{t('setTokenFeeBps')}</button>
            </form>
          </section>

          <datalist id="managed-token-list">
            {datalistTokens.map((token) => (
              <option key={token} value={token} />
            ))}
          </datalist>

          <section className="card tx-card">
            <h2>{t('txStatus')}</h2>
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
          </section>
        </>
      )}

      {isTokenCreatePage && (
        <section className="card tx-card">
          <h2>{t('txStatus')}</h2>
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
        </section>
      )}
    </div>
  );
}
