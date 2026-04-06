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
import { getAddress, isAddress, zeroAddress, type Address } from 'viem';

import { explorerAddressUrl, explorerTxUrl, networkConfig } from './config/chain';
import { contractEntries, contracts } from './config/contracts';
import { managedTokenAbi, ser9Abi, stakingAbi } from './contracts/abi';
import { useTxExecutor } from './hooks/useTxExecutor';
import { useI18n, type MessageKey } from './i18n';
import { equalsAddress, formatTokenAmount, shortenAddress } from './utils/format';
import {
  parseAddressStrict,
  parseBooleanFromSelect,
  parseHexOrDefault,
  parseNonNegativeBps,
  parsePositiveTokenAmount,
} from './utils/validation';

type TokenConfigValue = {
  exists: boolean;
  creator: Address;
  mintRate: bigint;
  feeEnabled: boolean;
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

  const { connect, connectors, isPending: isConnecting } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: isSwitchingNetwork } = useSwitchChain();

  const tx = useTxExecutor({
    onMined: () => {
      void queryClient.invalidateQueries();
    },
  });

  const [copiedId, setCopiedId] = useState<string>('');
  const [formError, setFormError] = useState<string | null>(null);

  const [ser9ApproveAmount, setSer9ApproveAmount] = useState('');
  const [ser9ApproveSpender, setSer9ApproveSpender] = useState<string>(contracts.stakingProxy);

  const [managedApproveToken, setManagedApproveToken] = useState('');
  const [managedApproveAmount, setManagedApproveAmount] = useState('');
  const [managedApproveSpender, setManagedApproveSpender] = useState<string>(contracts.stakingProxy);

  const [stakeAmount, setStakeAmount] = useState('');
  const [unstakeAmount, setUnstakeAmount] = useState('');
  const [lockAmount, setLockAmount] = useState('');
  const [unlockAmount, setUnlockAmount] = useState('');

  const [createName, setCreateName] = useState('');
  const [createSymbol, setCreateSymbol] = useState('');
  const [createMintRate, setCreateMintRate] = useState('');
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

  const [ownerRewardRate, setOwnerRewardRate] = useState('');
  const [ownerCreationFee, setOwnerCreationFee] = useState('');

  const [ownerFeeExemptToken, setOwnerFeeExemptToken] = useState('');
  const [ownerFeeExemptAccount, setOwnerFeeExemptAccount] = useState('');
  const [ownerFeeExemptState, setOwnerFeeExemptState] = useState('true');

  const [ownerFeeRecipientToken, setOwnerFeeRecipientToken] = useState('');
  const [ownerNewFeeRecipient, setOwnerNewFeeRecipient] = useState('');

  const [ownerManagedImpl, setOwnerManagedImpl] = useState<string>(contracts.managedTokenImplementation);
  const [ownerNewStakingContract, setOwnerNewStakingContract] = useState<string>(contracts.stakingProxy);
  const [ownerTransferOwner, setOwnerTransferOwner] = useState('');

  const [expertArmed, setExpertArmed] = useState(false);
  const [expertPhrase, setExpertPhrase] = useState('');

  const [expertUpgradeImpl, setExpertUpgradeImpl] = useState<string>(contracts.stakingImplementation);
  const [expertUpgradeData, setExpertUpgradeData] = useState('0x');

  const [expertNewSer9Impl, setExpertNewSer9Impl] = useState<string>(contracts.ser9Implementation);
  const [expertNewManagedImpl, setExpertNewManagedImpl] = useState<string>(contracts.managedTokenImplementation);
  const [expertSer9Data, setExpertSer9Data] = useState('0x');
  const [expertManagedData, setExpertManagedData] = useState('0x');

  const normalizedConnectedAddress = address ? getAddress(address) : undefined;
  const addressForReads = normalizedConnectedAddress ?? zeroAddress;

  const ownerRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'owner',
  });

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

  const connectedIsOwner = equalsAddress(ownerRead.data, normalizedConnectedAddress);
  const connectedIsCreator = equalsAddress(creatorTokenConfig?.creator, normalizedConnectedAddress);

  const onWrongChain = isConnected && chainId !== networkConfig.chainId;
  const expertReady = expertArmed && expertPhrase.trim() === 'I UNDERSTAND';

  const injectedConnector = connectors[0];

  const datalistTokens = useMemo(() => {
    return managedTokens.map((token) => token.toLowerCase());
  }, [managedTokens]);

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
      case 'INVALID_HEX':
        return t('invalidHex');
      default:
        return t('unknownError');
    }
  }

  function resetErrors() {
    setFormError(null);
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

  async function copyToClipboard(key: string, value: string) {
    try {
      await navigator.clipboard.writeText(value);
      setCopiedId(key);
      setTimeout(() => {
        setCopiedId('');
      }, 1500);
    } catch {
      setFormError(t('unknownError'));
    }
  }

  function onSubmit(event: FormEvent<HTMLFormElement>, handler: () => void) {
    event.preventDefault();
    void handler();
  }

  return (
    <div className="app-shell">
      <header className="hero">
        <div>
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
            <button
              type="button"
              className="primary"
              disabled={!injectedConnector || isConnecting}
              onClick={() => {
                if (!injectedConnector) {
                  return;
                }

                connect({ connector: injectedConnector });
              }}
            >
              {isConnecting ? t('connectPending') : t('connectWallet')}
            </button>
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
          <strong>
            {connectedIsOwner ? t('roleOwner') : connectedIsCreator ? t('roleCreator') : t('roleUser')}
          </strong>
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

      <section className="card">
        <h2>{t('contractAddresses')}</h2>
        <div className="address-list">
          {contractEntries.map((entry) => (
            <div className="address-row" key={entry.key}>
              <div>
                <strong>{entry.title}</strong>
                <p>{entry.address}</p>
              </div>
              <div className="address-actions">
                <button type="button" onClick={() => void copyToClipboard(entry.key, entry.address)}>
                  {copiedId === entry.key ? t('copied') : t('copy')}
                </button>
                <a href={explorerAddressUrl(entry.address)} target="_blank" rel="noreferrer">
                  {t('openExplorer')}
                </a>
              </div>
            </div>
          ))}
        </div>
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

        <div className="section-title">{t('userState')}</div>
        {isConnected ? (
          <div className="metric-grid">
            <MetricCard label={t('ser9Balance')} value={formatTokenAmount(ser9BalanceRead.data)} />
            <MetricCard label={t('stakedBalance')} value={formatTokenAmount(userStakedRead.data)} />
            <MetricCard label={t('lockedBalance')} value={formatTokenAmount(userLockedRead.data)} />
            <MetricCard label={t('unlockedBalance')} value={formatTokenAmount(userUnlockedRead.data)} />
            <MetricCard label={t('earnedRewards')} value={formatTokenAmount(userEarnedRead.data)} />
            <MetricCard label={t('unusedLocked')} value={formatTokenAmount(userUnusedRead.data)} />
            <MetricCard label={t('usedLocked')} value={formatTokenAmount(userUsedRead.data)} />
          </div>
        ) : (
          <p className="muted">{t('connectHint')}</p>
        )}
      </section>

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

          <form onSubmit={(event) => onSubmit(event, () => runWrite('stake', () => ({
            address: contracts.stakingProxy,
            abi: stakingAbi,
            functionName: 'stake',
            args: [parsePositiveTokenAmount(stakeAmount)],
          })))}>
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

          <form onSubmit={(event) => onSubmit(event, () => runWrite('lock', () => ({
            address: contracts.stakingProxy,
            abi: stakingAbi,
            functionName: 'lock',
            args: [parsePositiveTokenAmount(lockAmount)],
          })))}>
            <h3>{t('lock')}</h3>
            <input value={lockAmount} onChange={(e) => setLockAmount(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('lock')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite('unlockUnused', () => ({
            address: contracts.stakingProxy,
            abi: stakingAbi,
            functionName: 'unlockUnused',
            args: [parsePositiveTokenAmount(unlockAmount)],
          })))}>
            <h3>{t('unlockUnused')}</h3>
            <input value={unlockAmount} onChange={(e) => setUnlockAmount(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('unlockUnused')}</button>
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

          <form onSubmit={(event) => onSubmit(event, () => runWrite('createManagedToken', () => {
            const name = createName.trim();
            const symbol = createSymbol.trim();

            if (!name || !symbol) {
              throw new Error('INVALID_AMOUNT');
            }

            return {
              address: contracts.stakingProxy,
              abi: stakingAbi,
              functionName: 'createManagedToken',
              args: [
                name,
                symbol,
                parsePositiveTokenAmount(createMintRate),
                createFeeEnabled,
                createFeeEnabled ? parseNonNegativeBps(createFeeBps) : 0,
              ],
            };
          }))}>
            <h3>{t('createManagedToken')}</h3>
            <input value={createName} onChange={(e) => setCreateName(e.target.value)} placeholder={t('tokenName')} />
            <input value={createSymbol} onChange={(e) => setCreateSymbol(e.target.value)} placeholder={t('tokenSymbol')} />
            <input value={createMintRate} onChange={(e) => setCreateMintRate(e.target.value)} placeholder={t('mintRatePerToken')} />
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

      <section className="card">
        <h2>{t('ownerControls')}</h2>
        <div className="action-grid">
          <form onSubmit={(event) => onSubmit(event, () => runWrite(
            'pause',
            () => ({ address: contracts.stakingProxy, abi: stakingAbi, functionName: 'pause', args: [] }),
            () => (connectedIsOwner ? null : t('ownerOnly')),
          ))}>
            <h3>{t('pause')}</h3>
            <button type="submit">{t('pause')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite(
            'unpause',
            () => ({ address: contracts.stakingProxy, abi: stakingAbi, functionName: 'unpause', args: [] }),
            () => (connectedIsOwner ? null : t('ownerOnly')),
          ))}>
            <h3>{t('unpause')}</h3>
            <button type="submit">{t('unpause')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite(
            'setRewardRate',
            () => ({
              address: contracts.stakingProxy,
              abi: stakingAbi,
              functionName: 'setRewardRatePerBlock',
              args: [parsePositiveTokenAmount(ownerRewardRate)],
            }),
            () => (connectedIsOwner ? null : t('ownerOnly')),
          ))}>
            <h3>{t('setRewardRate')}</h3>
            <input value={ownerRewardRate} onChange={(e) => setOwnerRewardRate(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('submit')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite(
            'setTokenCreationFee',
            () => ({
              address: contracts.stakingProxy,
              abi: stakingAbi,
              functionName: 'setTokenCreationFee',
              args: [parsePositiveTokenAmount(ownerCreationFee)],
            }),
            () => (connectedIsOwner ? null : t('ownerOnly')),
          ))}>
            <h3>{t('setTokenCreationFee')}</h3>
            <input value={ownerCreationFee} onChange={(e) => setOwnerCreationFee(e.target.value)} placeholder={t('amount')} />
            <button type="submit">{t('submit')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite(
            'setFeeExempt',
            () => ({
              address: contracts.stakingProxy,
              abi: stakingAbi,
              functionName: 'setFeeExempt',
              args: [
                parseAddressStrict(ownerFeeExemptToken),
                parseAddressStrict(ownerFeeExemptAccount),
                parseBooleanFromSelect(ownerFeeExemptState),
              ],
            }),
            () => (connectedIsOwner ? null : t('ownerOnly')),
          ))}>
            <h3>{t('setFeeExempt')}</h3>
            <input list="managed-token-list" value={ownerFeeExemptToken} onChange={(e) => setOwnerFeeExemptToken(e.target.value)} placeholder={t('tokenAddress')} />
            <input value={ownerFeeExemptAccount} onChange={(e) => setOwnerFeeExemptAccount(e.target.value)} placeholder={t('accountAddress')} />
            <select value={ownerFeeExemptState} onChange={(e) => setOwnerFeeExemptState(e.target.value)}>
              <option value="true">{t('yes')}</option>
              <option value="false">{t('no')}</option>
            </select>
            <button type="submit">{t('submit')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite(
            'setTokenFeeRecipient',
            () => ({
              address: contracts.stakingProxy,
              abi: stakingAbi,
              functionName: 'setTokenFeeRecipient',
              args: [parseAddressStrict(ownerFeeRecipientToken), parseAddressStrict(ownerNewFeeRecipient)],
            }),
            () => (connectedIsOwner ? null : t('ownerOnly')),
          ))}>
            <h3>{t('setTokenFeeRecipient')}</h3>
            <input list="managed-token-list" value={ownerFeeRecipientToken} onChange={(e) => setOwnerFeeRecipientToken(e.target.value)} placeholder={t('tokenAddress')} />
            <input value={ownerNewFeeRecipient} onChange={(e) => setOwnerNewFeeRecipient(e.target.value)} placeholder={t('newFeeRecipient')} />
            <button type="submit">{t('submit')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite(
            'setManagedTokenImplementation',
            () => ({
              address: contracts.stakingProxy,
              abi: stakingAbi,
              functionName: 'setManagedTokenImplementation',
              args: [parseAddressStrict(ownerManagedImpl)],
            }),
            () => (connectedIsOwner ? null : t('ownerOnly')),
          ))}>
            <h3>{t('setManagedTokenImplementation')}</h3>
            <input value={ownerManagedImpl} onChange={(e) => setOwnerManagedImpl(e.target.value)} placeholder={t('newImplementation')} />
            <button type="submit">{t('submit')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite(
            'setSer9StakingContract',
            () => ({
              address: contracts.stakingProxy,
              abi: stakingAbi,
              functionName: 'setSer9StakingContract',
              args: [parseAddressStrict(ownerNewStakingContract)],
            }),
            () => (connectedIsOwner ? null : t('ownerOnly')),
          ))}>
            <h3>{t('setSer9StakingContract')}</h3>
            <input value={ownerNewStakingContract} onChange={(e) => setOwnerNewStakingContract(e.target.value)} placeholder={t('newImplementation')} />
            <button type="submit">{t('submit')}</button>
          </form>

          <form onSubmit={(event) => onSubmit(event, () => runWrite(
            'transferOwnership',
            () => ({
              address: contracts.stakingProxy,
              abi: stakingAbi,
              functionName: 'transferOwnership',
              args: [parseAddressStrict(ownerTransferOwner)],
            }),
            () => (connectedIsOwner ? null : t('ownerOnly')),
          ))}>
            <h3>{t('transferOwnership')}</h3>
            <input value={ownerTransferOwner} onChange={(e) => setOwnerTransferOwner(e.target.value)} placeholder={t('newOwner')} />
            <button type="submit">{t('submit')}</button>
          </form>
        </div>
      </section>

      <section className="card expert">
        <h2>{t('expertMode')}</h2>
        <p className="muted">{t('expertDescription')}</p>

        <label className="checkbox-row">
          <input type="checkbox" checked={expertArmed} onChange={(e) => setExpertArmed(e.target.checked)} />
          {t('armExpertMode')}
        </label>

        <label className="expert-confirm">
          <span>{t('confirmationPhraseLabel')}</span>
          <input value={expertPhrase} onChange={(e) => setExpertPhrase(e.target.value)} placeholder="I UNDERSTAND" />
          <small>{t('confirmationPhraseHelp')}</small>
        </label>

        <div className="expert-ready">{expertReady ? t('expertReady') : '-'}</div>

        <div className="action-grid">
          <form
            onSubmit={(event) =>
              onSubmit(event, () =>
                runWrite(
                  'upgradeToAndCall',
                  () => {
                    if (!expertReady) {
                      throw new Error('INVALID_AMOUNT');
                    }

                    return {
                      address: contracts.stakingProxy,
                      abi: stakingAbi,
                      functionName: 'upgradeToAndCall',
                      args: [parseAddressStrict(expertUpgradeImpl), parseHexOrDefault(expertUpgradeData)],
                    };
                  },
                  () => (connectedIsOwner ? null : t('ownerOnly')),
                ),
              )
            }
          >
            <h3>{t('upgradeToAndCall')}</h3>
            <input value={expertUpgradeImpl} onChange={(e) => setExpertUpgradeImpl(e.target.value)} placeholder={t('newImplementation')} />
            <input value={expertUpgradeData} onChange={(e) => setExpertUpgradeData(e.target.value)} placeholder={t('calldataHex')} />
            <small>{t('byteDefaultHint')}</small>
            <button type="submit" disabled={!expertReady}>{t('submit')}</button>
          </form>

          <form
            onSubmit={(event) =>
              onSubmit(event, () =>
                runWrite(
                  'upgradeTokens',
                  () => {
                    if (!expertReady) {
                      throw new Error('INVALID_AMOUNT');
                    }

                    return {
                      address: contracts.stakingProxy,
                      abi: stakingAbi,
                      functionName: 'upgradeTokens',
                      args: [
                        parseAddressStrict(expertNewSer9Impl),
                        parseAddressStrict(expertNewManagedImpl),
                        parseHexOrDefault(expertSer9Data),
                        parseHexOrDefault(expertManagedData),
                      ],
                    };
                  },
                  () => (connectedIsOwner ? null : t('ownerOnly')),
                ),
              )
            }
          >
            <h3>{t('upgradeTokens')}</h3>
            <input value={expertNewSer9Impl} onChange={(e) => setExpertNewSer9Impl(e.target.value)} placeholder={t('newSer9Implementation')} />
            <input value={expertNewManagedImpl} onChange={(e) => setExpertNewManagedImpl(e.target.value)} placeholder={t('newManagedImplementation')} />
            <input value={expertSer9Data} onChange={(e) => setExpertSer9Data(e.target.value)} placeholder={t('ser9Calldata')} />
            <input value={expertManagedData} onChange={(e) => setExpertManagedData(e.target.value)} placeholder={t('managedCalldata')} />
            <button type="submit" disabled={!expertReady}>{t('submit')}</button>
          </form>
        </div>
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
    </div>
  );
}
