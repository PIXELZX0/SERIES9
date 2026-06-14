import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
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
  useSignTypedData,
  useSwitchChain,
} from 'wagmi';
import { encodeFunctionData, getAddress, isAddress, isHex, maxUint256, zeroAddress, type Address, type Hex } from 'viem';

import { explorerTxUrl, networkConfig } from './config/chain';
import { contracts } from './config/contracts';
import { identityAbi, ser9Abi, stakingAbi } from './contracts/abi';
import { useTxExecutor } from './hooks/useTxExecutor';
import { type MessageKey } from './i18n';
import { useI18n } from './i18n/useI18n';
import { formatRewardAmount, formatTokenAmount, shortenAddress } from './utils/format';
import { parsePositiveTokenAmount } from './utils/validation';
import {
  DEFAULT_AVATAR_CONFIG,
  equalConfig as equalAvatarConfig,
  type AvatarConfig,
} from './utils/avatarRenderer';
import { AvatarBuilder } from './components/AvatarBuilder';

type ActionModalType = 'ser9Stake' | 'ser9Unstake' | 'monadStake' | 'monadUnstake';
type IdentityEntityType = 'human' | 'ai';
type PaymentAssetType = 'mon' | 'erc20';

type PaymentRequestValue = {
  id: bigint;
  payerTokenId: bigint;
  payeeTokenId: bigint;
  token: Address;
  amount: bigint;
  dueAt: bigint;
  status: number;
  memo: string;
};

type IdentityTokenMetadata = {
  name?: string;
  description?: string;
  image?: string;
  image_data?: string;
};



type UnstakeRequestValue = {
  amount: bigint;
  requestEpoch: number;
  minClaimEpoch: number;
  claimed: boolean;
};

const monadStakingPrecompileAbi = [
  {
    type: 'function',
    name: 'getEpoch',
    inputs: [],
    outputs: [
      { name: 'epoch', type: 'uint64', internalType: 'uint64' },
      { name: 'inEpochDelayPeriod', type: 'bool', internalType: 'bool' },
    ],
    stateMutability: 'nonpayable',
  },
] as const;

const MONAD_STAKING_PRECOMPILE = getAddress('0x0000000000000000000000000000000000001000');
const MONAD_EPOCH_APPROX_MS = 5.5 * 60 * 60 * 1000;
const UTF8_ENCODER = new TextEncoder();
const UTF8_DECODER = new TextDecoder();
const IDENTITY_NAME_MAX_BYTES = 32;
const IDENTITY_BIO_MAX_BYTES = 128;
const PAYMENT_HANDLE_PATTERN = /^[a-z0-9](?:[a-z0-9-]{1,30}[a-z0-9])$/;
const PAYMENT_MEMO_MAX_BYTES = 128;
const LEGACY_HANDLE_SEED_BATCH = 1000n;
const DEFAULT_AI_MINT_FEE = 10n * 10n ** 18n;
const DEFAULT_HUMAN_MINT_FEE = 50n * 10n ** 18n;
const PAYMENT_STATUS = {
  pending: 1,
  paid: 2,
  cancelled: 3,
  expired: 4,
} as const;

function utf8ByteLength(value: string): number {
  return UTF8_ENCODER.encode(value).length;
}

function validateUint8(value: number): number {
  if (!Number.isInteger(value) || value < 0 || value > 255) {
    throw new Error('INVALID_IDENTITY_COLOR');
  }

  return value;
}

function identityAccentColor(hue: number, saturation: number): string {
  const hueDegrees = Math.round((hue / 255) * 360);
  const saturationPercent = Math.round(36 + (saturation / 255) * 54);
  return `hsl(${hueDegrees} ${saturationPercent}% 56%)`;
}

function decodeBase64Utf8(value: string): string {
  const binary = atob(value);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return UTF8_DECODER.decode(bytes);
}

function decodeDataUri(uri: string): string | null {
  const commaIndex = uri.indexOf(',');
  if (!uri.startsWith('data:') || commaIndex === -1) {
    return null;
  }

  const header = uri.slice(0, commaIndex).toLowerCase();
  const body = uri.slice(commaIndex + 1);

  try {
    if (header.endsWith(';base64')) {
      return decodeBase64Utf8(body);
    }

    return decodeURIComponent(body);
  } catch {
    return null;
  }
}

function parseIdentityTokenMetadata(tokenUri: string | undefined): IdentityTokenMetadata | null {
  if (!tokenUri) {
    return null;
  }

  const metadataJson = tokenUri.startsWith('data:')
    ? decodeDataUri(tokenUri)
    : tokenUri;

  if (!metadataJson) {
    return null;
  }

  try {
    const parsed = JSON.parse(metadataJson) as unknown;
    if (!parsed || typeof parsed !== 'object') {
      return null;
    }

    const metadata = parsed as IdentityTokenMetadata;
    return {
      name: typeof metadata.name === 'string' ? metadata.name : undefined,
      description: typeof metadata.description === 'string' ? metadata.description : undefined,
      image: typeof metadata.image === 'string' ? metadata.image : undefined,
      image_data: typeof metadata.image_data === 'string' ? metadata.image_data : undefined,
    };
  } catch {
    return null;
  }
}

function resolveIdentityImageSrc(metadata: IdentityTokenMetadata | null): string | null {
  const image = metadata?.image ?? metadata?.image_data;
  if (!image) {
    return null;
  }

  if (image.trim().startsWith('<svg')) {
    return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(image)}`;
  }

  return image;
}

function formatApproxRemainingEpochTime(locale: string, remainingEpochs: number): string {
  const remainingMilliseconds = remainingEpochs * MONAD_EPOCH_APPROX_MS;
  const totalMinutes = Math.ceil(remainingMilliseconds / 60_000);
  const days = Math.floor(totalMinutes / (60 * 24));
  const hours = Math.floor((totalMinutes % (60 * 24)) / 60);
  const minutes = totalMinutes % 60;

  if (locale === 'ko') {
    const segments = [
      days > 0 ? `${days}일` : null,
      hours > 0 ? `${hours}시간` : null,
      minutes > 0 ? `${minutes}분` : null,
    ].filter((segment): segment is string => Boolean(segment));

    return `약 ${segments.join(' ')}`;
  }

  const segments = [
    days > 0 ? `${days}d` : null,
    hours > 0 ? `${hours}h` : null,
    minutes > 0 ? `${minutes}m` : null,
  ].filter((segment): segment is string => Boolean(segment));

  return `~${segments.join(' ')}`;
}



function parseUnstakeRequest(raw: unknown): UnstakeRequestValue | null {
  if (!raw) {
    return null;
  }

  if (Array.isArray(raw)) {
    const [amount, requestEpoch, minClaimEpoch, claimed] = raw;

    if (
      typeof amount === 'bigint' &&
      (typeof requestEpoch === 'number' || typeof requestEpoch === 'bigint') &&
      (typeof minClaimEpoch === 'number' || typeof minClaimEpoch === 'bigint') &&
      typeof claimed === 'boolean'
    ) {
      return {
        amount,
        requestEpoch: Number(requestEpoch),
        minClaimEpoch: Number(minClaimEpoch),
        claimed,
      };
    }
  }

  if (typeof raw === 'object') {
    const value = raw as {
      amount?: unknown;
      requestEpoch?: unknown;
      minClaimEpoch?: unknown;
      claimed?: unknown;
    };

    if (
      typeof value.amount === 'bigint' &&
      (typeof value.requestEpoch === 'number' || typeof value.requestEpoch === 'bigint') &&
      (typeof value.minClaimEpoch === 'number' || typeof value.minClaimEpoch === 'bigint') &&
      typeof value.claimed === 'boolean'
    ) {
      return {
        amount: value.amount,
        requestEpoch: Number(value.requestEpoch),
        minClaimEpoch: Number(value.minClaimEpoch),
        claimed: value.claimed,
      };
    }
  }

  return null;
}

function parsePaymentRequest(id: bigint, raw: unknown): PaymentRequestValue | null {
  if (!raw) {
    return null;
  }

  const normalizeStatus = (value: unknown): number | null => {
    if (typeof value === 'number') {
      return value;
    }
    if (typeof value === 'bigint') {
      return Number(value);
    }
    return null;
  };

  const normalizeDueAt = (value: unknown): bigint | null => {
    if (typeof value === 'bigint') {
      return value;
    }
    if (typeof value === 'number') {
      return BigInt(value);
    }
    return null;
  };

  const build = (
    payerTokenId: unknown,
    payeeTokenId: unknown,
    token: unknown,
    amount: unknown,
    dueAt: unknown,
    status: unknown,
    memo: unknown,
  ) => {
    const normalizedDueAt = normalizeDueAt(dueAt);
    const normalizedStatus = normalizeStatus(status);
    if (
      typeof payerTokenId === 'bigint' &&
      typeof payeeTokenId === 'bigint' &&
      typeof token === 'string' &&
      typeof amount === 'bigint' &&
      normalizedDueAt !== null &&
      normalizedStatus !== null &&
      typeof memo === 'string'
    ) {
      return {
        id,
        payerTokenId,
        payeeTokenId,
        token: getAddress(token),
        amount,
        dueAt: normalizedDueAt,
        status: normalizedStatus,
        memo,
      };
    }

    return null;
  };

  if (Array.isArray(raw)) {
    return build(raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6]);
  }

  if (typeof raw === 'object') {
    const value = raw as {
      payerTokenId?: unknown;
      payeeTokenId?: unknown;
      token?: unknown;
      amount?: unknown;
      dueAt?: unknown;
      status?: unknown;
      memo?: unknown;
    };

    return build(
      value.payerTokenId,
      value.payeeTokenId,
      value.token,
      value.amount,
      value.dueAt,
      value.status,
      value.memo,
    );
  }

  return null;
}

function validatePaymentHandle(value: string): string {
  const handle = value.trim();
  if (!PAYMENT_HANDLE_PATTERN.test(handle)) {
    throw new Error('INVALID_PAYMENT_HANDLE');
  }
  return handle;
}

function validatePaymentMemo(value: string): string {
  const memo = value.trim();
  if (utf8ByteLength(memo) > PAYMENT_MEMO_MAX_BYTES) {
    throw new Error('INVALID_PAYMENT_MEMO');
  }
  return memo;
}

function parsePaymentDueAt(value: string): bigint {
  const trimmed = value.trim();
  if (!trimmed) {
    return 0n;
  }

  const timestampMs = Date.parse(trimmed);
  if (!Number.isFinite(timestampMs) || timestampMs <= Date.now()) {
    throw new Error('INVALID_PAYMENT_DUE_AT');
  }

  return BigInt(Math.floor(timestampMs / 1000));
}

function resolvePaymentToken(assetType: PaymentAssetType, tokenAddress: string): Address {
  if (assetType === 'mon') {
    return zeroAddress;
  }

  const trimmed = tokenAddress.trim();
  if (!isAddress(trimmed)) {
    throw new Error('INVALID_ADDRESS');
  }

  return getAddress(trimmed);
}

function isPaymentRequestExpired(request: PaymentRequestValue): boolean {
  return request.status === PAYMENT_STATUS.pending && request.dueAt > 0n && BigInt(Math.floor(Date.now() / 1000)) > request.dueAt;
}

function paymentRequestEffectiveStatus(request: PaymentRequestValue): number {
  return isPaymentRequestExpired(request) ? PAYMENT_STATUS.expired : request.status;
}

function MetricCard({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="metric-card">
      <span className="metric-label">{label}</span>
      <div className="metric-value">{value}</div>
    </div>
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

  const { signTypedDataAsync } = useSignTypedData();

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
  const [identityName, setIdentityName] = useState('');
  const [identityBio, setIdentityBio] = useState('');
  const [identityEntityType, setIdentityEntityType] = useState<IdentityEntityType>('human');
  const [identityHue, setIdentityHue] = useState(145);
  const [identitySaturation, setIdentitySaturation] = useState(180);
  const [avatarDraft, setAvatarDraft] = useState<AvatarConfig>(DEFAULT_AVATAR_CONFIG);
  const [paymentHandle, setPaymentHandle] = useState('');
  const [paymentAssetType, setPaymentAssetType] = useState<PaymentAssetType>('mon');
  const [paymentTokenAddress, setPaymentTokenAddress] = useState<string>(contracts.ser9Proxy);
  const [paymentRecipientHandle, setPaymentRecipientHandle] = useState('');
  const [paymentAmount, setPaymentAmount] = useState('');
  const [paymentMemo, setPaymentMemo] = useState('');
  const [requestAssetType, setRequestAssetType] = useState<PaymentAssetType>('mon');
  const [requestTokenAddress, setRequestTokenAddress] = useState<string>(contracts.ser9Proxy);
  const [requestPayerHandle, setRequestPayerHandle] = useState('');
  const [requestAmount, setRequestAmount] = useState('');
  const [requestDueAt, setRequestDueAt] = useState('');
  const [requestMemo, setRequestMemo] = useState('');
  const [delegatedSignatureRequestId, setDelegatedSignatureRequestId] = useState('');
  const [delegatedSignatureDeadlineMinutes, setDelegatedSignatureDeadlineMinutes] = useState('60');
  const [delegatedSignatureOutput, setDelegatedSignatureOutput] = useState<{
    requestId: string;
    nonce: string;
    deadline: string;
    signature: Hex;
    signer: Address;
  } | null>(null);
  const [relayPaymentPayload, setRelayPaymentPayload] = useState('');

  const normalizedConnectedAddress = address ? getAddress(address) : undefined;
  const addressForReads = normalizedConnectedAddress ?? zeroAddress;
  const normalizedPaymentTokenAddress = paymentAssetType === 'erc20' && isAddress(paymentTokenAddress.trim())
    ? getAddress(paymentTokenAddress.trim())
    : undefined;
  const normalizedRequestTokenAddress = requestAssetType === 'erc20' && isAddress(requestTokenAddress.trim())
    ? getAddress(requestTokenAddress.trim())
    : undefined;

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

  const identityAllowanceRead = useReadContract({
    address: contracts.ser9Proxy,
    abi: ser9Abi,
    functionName: 'allowance',
    args: [addressForReads, contracts.identityProxy],
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

  const ser9BalanceRead = useReadContract({
    address: contracts.ser9Proxy,
    abi: ser9Abi,
    functionName: 'balanceOf',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const identityPausedRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'paused',
  });

  const identityAiMintFeeRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'aiMintFee',
  });

  const identityHumanMintFeeRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'humanMintFee',
  });

  const identityOwnerTokenIdRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'ownerTokenId',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });
  const identityTokenIdForReads = identityOwnerTokenIdRead.data ?? 0n;

  const identityHandleRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'handleOf',
    args: [identityTokenIdForReads],
    query: {
      enabled: identityTokenIdForReads > 0n,
    },
  });

  const identityTokenUriRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'tokenURI',
    args: [identityTokenIdForReads],
    query: {
      enabled: identityTokenIdForReads > 0n,
    },
  });

  const identityAvatarConfigRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'avatarConfig',
    args: [identityTokenIdForReads],
    query: {
      enabled: identityTokenIdForReads > 0n,
    },
  });

  const legacyHandleReservationsFinalizedRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'legacyHandleReservationsFinalized',
    query: {
      enabled: identityTokenIdForReads > 0n,
    },
  });

  const legacyHandlePriorityDeadlineRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'legacyHandlePriorityDeadline',
    query: {
      enabled: identityTokenIdForReads > 0n,
    },
  });

  const identityNameRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'nameOf',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const identityIsAIRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'isAI',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const identityReputationRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'reputationScoreOf',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const identityPendingRewardsRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'pendingNFTRewards',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
      refetchInterval: 10_000,
    },
  });

  const identityPendingStakingRewardsRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'pendingStakingRewards',
    query: {
      refetchInterval: 10_000,
    },
  });

  const directPaymentAllowanceRead = useReadContract({
    address: normalizedPaymentTokenAddress ?? contracts.ser9Proxy,
    abi: ser9Abi,
    functionName: 'allowance',
    args: [addressForReads, contracts.identityProxy],
    query: {
      enabled: Boolean(normalizedConnectedAddress) && paymentAssetType === 'erc20' && Boolean(normalizedPaymentTokenAddress),
    },
  });

  const requestPaymentAllowanceRead = useReadContract({
    address: normalizedRequestTokenAddress ?? contracts.ser9Proxy,
    abi: ser9Abi,
    functionName: 'allowance',
    args: [addressForReads, contracts.identityProxy],
    query: {
      enabled: Boolean(normalizedConnectedAddress) && requestAssetType === 'erc20' && Boolean(normalizedRequestTokenAddress),
    },
  });

  const payerPaymentRequestCountRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'payerPaymentRequestCount',
    args: [identityTokenIdForReads],
    query: {
      enabled: identityTokenIdForReads > 0n,
    },
  });

  const payeePaymentRequestCountRead = useReadContract({
    address: contracts.identityProxy,
    abi: identityAbi,
    functionName: 'payeePaymentRequestCount',
    args: [identityTokenIdForReads],
    query: {
      enabled: identityTokenIdForReads > 0n,
    },
  });
  const payerPaymentRequestCount = Number(payerPaymentRequestCountRead.data ?? 0n);
  const payeePaymentRequestCount = Number(payeePaymentRequestCountRead.data ?? 0n);

  const payerPaymentRequestIdContracts = useMemo(
    () =>
      Array.from({ length: payerPaymentRequestCount }, (_, index) => ({
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'payerPaymentRequestIdAt' as const,
        args: [identityTokenIdForReads, BigInt(index)] as const,
      })),
    [identityTokenIdForReads, payerPaymentRequestCount],
  );

  const payeePaymentRequestIdContracts = useMemo(
    () =>
      Array.from({ length: payeePaymentRequestCount }, (_, index) => ({
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'payeePaymentRequestIdAt' as const,
        args: [identityTokenIdForReads, BigInt(index)] as const,
      })),
    [identityTokenIdForReads, payeePaymentRequestCount],
  );

  const payerPaymentRequestIdsRead = useReadContracts({
    contracts: payerPaymentRequestIdContracts,
    query: {
      enabled: identityTokenIdForReads > 0n && payerPaymentRequestIdContracts.length > 0,
    },
  });

  const payeePaymentRequestIdsRead = useReadContracts({
    contracts: payeePaymentRequestIdContracts,
    query: {
      enabled: identityTokenIdForReads > 0n && payeePaymentRequestIdContracts.length > 0,
    },
  });

  const payerPaymentRequestIds = useMemo(
    () =>
      (payerPaymentRequestIdsRead.data ?? [])
        .filter((result) => result.status === 'success' && typeof result.result === 'bigint')
        .map((result) => result.result as bigint),
    [payerPaymentRequestIdsRead.data],
  );

  const payeePaymentRequestIds = useMemo(
    () =>
      (payeePaymentRequestIdsRead.data ?? [])
        .filter((result) => result.status === 'success' && typeof result.result === 'bigint')
        .map((result) => result.result as bigint),
    [payeePaymentRequestIdsRead.data],
  );

  const paymentRequestIds = useMemo(() => {
    const unique = new Map<string, bigint>();
    for (const requestId of [...payerPaymentRequestIds, ...payeePaymentRequestIds]) {
      unique.set(requestId.toString(), requestId);
    }
    return Array.from(unique.values());
  }, [payeePaymentRequestIds, payerPaymentRequestIds]);

  const paymentRequestReadContracts = useMemo(
    () =>
      paymentRequestIds.map((requestId) => ({
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'paymentRequest' as const,
        args: [requestId] as const,
      })),
    [paymentRequestIds],
  );

  const paymentRequestsRead = useReadContracts({
    contracts: paymentRequestReadContracts,
    query: {
      enabled: paymentRequestReadContracts.length > 0,
      refetchInterval: 10_000,
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

  const monadUnstakeRequestCountRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'monadUnstakeRequestCount',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const ser9UnstakeRequestCountRead = useReadContract({
    address: contracts.stakingProxy,
    abi: stakingAbi,
    functionName: 'ser9UnstakeRequestCount',
    args: [addressForReads],
    query: {
      enabled: Boolean(normalizedConnectedAddress),
    },
  });

  const currentMonadEpochRead = useReadContract({
    address: MONAD_STAKING_PRECOMPILE,
    abi: monadStakingPrecompileAbi,
    functionName: 'getEpoch',
    query: {
      refetchInterval: 60_000,
    },
  });

  const monadUnstakeRequestCount = Number(monadUnstakeRequestCountRead.data ?? 0n);
  const ser9UnstakeRequestCount = Number(ser9UnstakeRequestCountRead.data ?? 0n);

  const monadUnstakeRequestContracts = useMemo(
    () =>
      Array.from({ length: monadUnstakeRequestCount }, (_, index) => ({
        address: contracts.stakingProxy,
        abi: stakingAbi,
        functionName: 'monadUnstakeRequest' as const,
        args: [addressForReads, BigInt(index)] as const,
      })),
    [addressForReads, monadUnstakeRequestCount],
  );

  const ser9UnstakeRequestContracts = useMemo(
    () =>
      Array.from({ length: ser9UnstakeRequestCount }, (_, index) => ({
        address: contracts.stakingProxy,
        abi: stakingAbi,
        functionName: 'ser9UnstakeRequest' as const,
        args: [addressForReads, BigInt(index)] as const,
      })),
    [addressForReads, ser9UnstakeRequestCount],
  );

  const monadUnstakeRequestsRead = useReadContracts({
    contracts: monadUnstakeRequestContracts,
    query: {
      enabled: Boolean(normalizedConnectedAddress) && monadUnstakeRequestContracts.length > 0,
    },
  });

  const ser9UnstakeRequestsRead = useReadContracts({
    contracts: ser9UnstakeRequestContracts,
    query: {
      enabled: Boolean(normalizedConnectedAddress) && ser9UnstakeRequestContracts.length > 0,
    },
  });


  const paymentRequests = useMemo(() => {
    const parsed: PaymentRequestValue[] = [];

    for (let index = 0; index < (paymentRequestsRead.data ?? []).length; index++) {
      const result = paymentRequestsRead.data?.[index];
      const requestId = paymentRequestIds[index];
      if (!result || result.status !== 'success' || requestId === undefined) {
        continue;
      }

      const request = parsePaymentRequest(requestId, result.result);
      if (request) {
        parsed.push(request);
      }
    }

    return parsed;
  }, [paymentRequestIds, paymentRequestsRead.data]);

  const incomingPaymentRequests = useMemo(
    () => paymentRequests.filter((request) => request.payerTokenId === identityTokenIdForReads),
    [identityTokenIdForReads, paymentRequests],
  );

  const outgoingPaymentRequests = useMemo(
    () => paymentRequests.filter((request) => request.payeeTokenId === identityTokenIdForReads),
    [identityTokenIdForReads, paymentRequests],
  );

  const pendingMonadUnstakeSummary = useMemo(() => {
    let totalAmount = 0n;
    let latestMinClaimEpoch = 0;

    for (const result of monadUnstakeRequestsRead.data ?? []) {
      if (result.status !== 'success') {
        continue;
      }

      const request = parseUnstakeRequest(result.result);
      if (!request || request.claimed) {
        continue;
      }

      totalAmount += request.amount;
      latestMinClaimEpoch = Math.max(latestMinClaimEpoch, request.minClaimEpoch);
    }

    return {
      totalAmount,
      latestMinClaimEpoch,
    };
  }, [monadUnstakeRequestsRead.data]);

  const pendingSer9UnstakeSummary = useMemo(() => {
    if (ser9UnstakeRequestCount === 0) {
      return {
        totalAmount: 0n,
        latestMinClaimEpoch: 0,
      };
    }

    const results = ser9UnstakeRequestsRead.data;
    if (!results || results.length !== ser9UnstakeRequestCount) {
      return undefined;
    }

    let totalAmount = 0n;
    let latestMinClaimEpoch = 0;

    for (const result of results) {
      if (result.status !== 'success') {
        return undefined;
      }

      const request = parseUnstakeRequest(result.result);
      if (!request) {
        return undefined;
      }

      if (!request.claimed) {
        totalAmount += request.amount;
        latestMinClaimEpoch = Math.max(latestMinClaimEpoch, request.minClaimEpoch);
      }
    }

    return {
      totalAmount,
      latestMinClaimEpoch,
    };
  }, [ser9UnstakeRequestCount, ser9UnstakeRequestsRead.data]);

  const currentMonadEpoch = useMemo(() => {
    const value = currentMonadEpochRead.data as unknown;

    if (!value) {
      return null;
    }

    if (Array.isArray(value)) {
      const [epoch] = value;
      if (typeof epoch === 'number' || typeof epoch === 'bigint') {
        return Number(epoch);
      }
    }

    if (typeof value === 'object' && value !== null) {
      const parsedValue = value as { epoch?: unknown };
      if (typeof parsedValue.epoch === 'number' || typeof parsedValue.epoch === 'bigint') {
        return Number(parsedValue.epoch);
      }
    }

    return null;
  }, [currentMonadEpochRead.data]);

  const firstClaimableMonadUnstakeRequestId = useMemo(() => {
    if (currentMonadEpoch === null) {
      return null;
    }

    for (const [index, result] of (monadUnstakeRequestsRead.data ?? []).entries()) {
      if (result.status !== 'success') {
        continue;
      }

      const request = parseUnstakeRequest(result.result);
      if (!request || request.claimed || request.minClaimEpoch > currentMonadEpoch) {
        continue;
      }

      return BigInt(index);
    }

    return null;
  }, [currentMonadEpoch, monadUnstakeRequestsRead.data]);

  const firstClaimableSer9UnstakeRequestId = useMemo(() => {
    if (currentMonadEpoch === null) {
      return null;
    }

    for (const [index, result] of (ser9UnstakeRequestsRead.data ?? []).entries()) {
      if (result.status !== 'success') {
        continue;
      }

      const request = parseUnstakeRequest(result.result);
      if (!request || request.claimed || request.minClaimEpoch > currentMonadEpoch) {
        continue;
      }

      return BigInt(index);
    }

    return null;
  }, [currentMonadEpoch, ser9UnstakeRequestsRead.data]);

  const pendingMonadUnstakeRemainingTime = useMemo(() => {
    if (pendingMonadUnstakeSummary.totalAmount === 0n) {
      return null;
    }

    if (currentMonadEpoch === null) {
      return '-';
    }

    const remainingEpochs = Math.max(pendingMonadUnstakeSummary.latestMinClaimEpoch - currentMonadEpoch, 0);
    if (remainingEpochs === 0) {
      return t('readyToClaim');
    }

    return formatApproxRemainingEpochTime(locale, remainingEpochs);
  }, [currentMonadEpoch, locale, pendingMonadUnstakeSummary.latestMinClaimEpoch, pendingMonadUnstakeSummary.totalAmount, t]);

  const pendingSer9UnstakeRemainingTime = useMemo(() => {
    if (pendingSer9UnstakeSummary === undefined) {
      return ser9UnstakeRequestCount > 0 ? '-' : null;
    }

    if (pendingSer9UnstakeSummary.totalAmount === 0n) {
      return null;
    }

    if (currentMonadEpoch === null) {
      return '-';
    }

    const remainingEpochs = Math.max(pendingSer9UnstakeSummary.latestMinClaimEpoch - currentMonadEpoch, 0);
    if (remainingEpochs === 0) {
      return t('readyToClaim');
    }

    return formatApproxRemainingEpochTime(locale, remainingEpochs);
  }, [currentMonadEpoch, locale, pendingSer9UnstakeSummary, ser9UnstakeRequestCount, t]);

  const onWrongChain = isConnected && chainId !== networkConfig.chainId;
  const totalClaimableRewards = userEarnedRead.data ?? 0n;
  const monadClaimableRewards = userMonadEarnedRead.data ?? 0n;
  const ser9ClaimableRewards = totalClaimableRewards > monadClaimableRewards
    ? totalClaimableRewards - monadClaimableRewards
    : 0n;
  const identityTokenId = identityTokenIdForReads;
  const hasIdentity = identityTokenId > 0n;
  const selectedIdentityFeeRead = identityEntityType === 'ai'
    ? identityAiMintFeeRead.data
    : identityHumanMintFeeRead.data;
  const selectedIdentityFee = selectedIdentityFeeRead
    ?? (identityEntityType === 'ai' ? DEFAULT_AI_MINT_FEE : DEFAULT_HUMAN_MINT_FEE);
  const identityNeedsApproval =
    !hasIdentity &&
    selectedIdentityFee > 0n &&
    (selectedIdentityFeeRead === undefined || (identityAllowanceRead.data ?? 0n) < selectedIdentityFee);
  const identityNameBytes = utf8ByteLength(identityName.trim());
  const identityBioBytes = utf8ByteLength(identityBio.trim());
  const identityPreviewColor = identityAccentColor(identityHue, identitySaturation);
  const identityDisplayType = identityIsAIRead.data === undefined
    ? '-'
    : identityIsAIRead.data
      ? t('identityAI')
      : t('identityHuman');
  const identityTokenMetadata = useMemo(
    () => parseIdentityTokenMetadata(identityTokenUriRead.data),
    [identityTokenUriRead.data],
  );
  const identityNftImageSrc = resolveIdentityImageSrc(identityTokenMetadata);
  const identityDisplayName = hasIdentity
    ? identityTokenMetadata?.name || identityNameRead.data || 'SERIES9'
    : identityName.trim() || 'SERIES9';
  const currentIdentityHandle = identityHandleRead.data ?? '';
  const hasEnteredPaymentHandle = paymentHandle.trim().length > 0;
  const paymentHandleBytes = utf8ByteLength(paymentHandle.trim());
  const paymentMemoBytes = utf8ByteLength(paymentMemo.trim());
  const requestMemoBytes = utf8ByteLength(requestMemo.trim());
  const parsedPaymentAmount = useMemo(() => {
    try {
      return paymentAmount.trim() ? parsePositiveTokenAmount(paymentAmount) : null;
    } catch {
      return null;
    }
  }, [paymentAmount]);
  const parsedRequestAmount = useMemo(() => {
    try {
      return requestAmount.trim() ? parsePositiveTokenAmount(requestAmount) : null;
    } catch {
      return null;
    }
  }, [requestAmount]);
  const directPaymentNeedsApproval =
    paymentAssetType === 'erc20' &&
    parsedPaymentAmount !== null &&
    Boolean(normalizedPaymentTokenAddress) &&
    (directPaymentAllowanceRead.data === undefined || directPaymentAllowanceRead.data < parsedPaymentAmount);
  const requestPaymentNeedsApproval =
    requestAssetType === 'erc20' &&
    parsedRequestAmount !== null &&
    Boolean(normalizedRequestTokenAddress) &&
    (requestPaymentAllowanceRead.data === undefined || requestPaymentAllowanceRead.data < parsedRequestAmount);

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
  const isIdentityPage = normalizedPathname === '/identity';
  const isPaymentPage = normalizedPathname === '/payment';
  const isStakingPage = normalizedPathname === '/staking';
  const isHomePage =
    !isTokensListPage && !isTokenCreatePage && !isIdentityPage && !isPaymentPage && !isStakingPage;
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
    void identityPendingRewardsRead.refetch();
    void identityPendingStakingRewardsRead.refetch();
  }, [
    identityPendingRewardsRead,
    identityPendingStakingRewardsRead,
    latestBlockNumber.data,
    normalizedConnectedAddress,
    userEarnedRead,
    userMonadEarnedRead,
  ]);

  useEffect(() => {
    if (hasTxActivity) {
      setIsTxModalOpen(true);
    }
  }, [hasTxActivity]);

  useEffect(() => {
    if (identityHandleRead.data && !paymentHandle) {
      setPaymentHandle(identityHandleRead.data);
    }
  }, [identityHandleRead.data, paymentHandle]);

  const currentAvatarConfig = useMemo<AvatarConfig>(() => {
    const data = identityAvatarConfigRead.data;
    if (!data) return DEFAULT_AVATAR_CONFIG;
    const [skinTone, hairStyle, hairColor, eyes, mouth, outfit, accessory, background] = data;
    return { skinTone, hairStyle, hairColor, eyes, mouth, outfit, accessory, background };
  }, [identityAvatarConfigRead.data]);

  useEffect(() => {
    setAvatarDraft(currentAvatarConfig);
  }, [currentAvatarConfig]);

  const avatarDirty = !equalAvatarConfig(avatarDraft, currentAvatarConfig);

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
      case 'INVALID_IDENTITY_NAME':
        return t('invalidIdentityName');
      case 'INVALID_IDENTITY_BIO':
        return t('invalidIdentityBio');
      case 'INVALID_IDENTITY_COLOR':
        return t('invalidIdentityColor');
      case 'IDENTITY_ALREADY_EXISTS':
        return t('alreadyHasIdentity');
      case 'NO_IDENTITY_REWARDS':
        return t('noIdentityRewards');
      case 'INVALID_PAYMENT_HANDLE':
        return t('invalidPaymentHandle');
      case 'INVALID_PAYMENT_MEMO':
        return t('invalidPaymentMemo');
      case 'INVALID_PAYMENT_DUE_AT':
        return t('invalidPaymentDueAt');
      case 'LEGACY_HANDLES_PENDING':
        return t('legacyHandlesPending');
      case 'REQUIRED_FIELD':
        return t('requiredField');
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

  async function ensureHandleRegistrationReady() {
    if (!publicClient) {
      if (legacyHandleReservationsFinalizedRead.data === false) {
        throw new Error('LEGACY_HANDLES_PENDING');
      }
      return;
    }

    let finalized = legacyHandleReservationsFinalizedRead.data;
    if (finalized === undefined) {
      finalized = await publicClient.readContract({
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'legacyHandleReservationsFinalized',
      });
    }

    if (finalized !== false) {
      return;
    }

    let priorityDeadline = legacyHandlePriorityDeadlineRead.data;
    if (priorityDeadline === undefined) {
      priorityDeadline = await publicClient.readContract({
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'legacyHandlePriorityDeadline',
      });
    }

    if (priorityDeadline > 0n) {
      const latestBlock = await publicClient.getBlock();
      if (latestBlock.timestamp > priorityDeadline) {
        return;
      }
    }

    const seedHash = await tx.execute(t('prepareLegacyHandles'), {
      address: contracts.identityProxy,
      abi: identityAbi,
      functionName: 'seedLegacyHandleReservations',
      args: [LEGACY_HANDLE_SEED_BATCH],
    });

    if (!seedHash) {
      throw new Error('LEGACY_HANDLES_PENDING');
    }

    await publicClient.waitForTransactionReceipt({ hash: seedHash });
    finalized = await publicClient.readContract({
      address: contracts.identityProxy,
      abi: identityAbi,
      functionName: 'legacyHandleReservationsFinalized',
    });

    if (finalized === false) {
      throw new Error('LEGACY_HANDLES_PENDING');
    }

    await queryClient.invalidateQueries();
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

  async function runMintIdentityFlow() {
    resetErrors();

    if (!normalizedConnectedAddress) {
      setFormError(t('connectHint'));
      return undefined;
    }

    if (hasIdentity) {
      return await runSetPaymentHandleFlow();
    }

    try {
      const name = identityName.trim();
      const bio = identityBio.trim();

      if (!name) {
        throw new Error('REQUIRED_FIELD');
      }

      if (utf8ByteLength(name) > IDENTITY_NAME_MAX_BYTES) {
        throw new Error('INVALID_IDENTITY_NAME');
      }

      if (utf8ByteLength(bio) > IDENTITY_BIO_MAX_BYTES) {
        throw new Error('INVALID_IDENTITY_BIO');
      }

      const entityTypeValue = identityEntityType === 'ai' ? 1 : 0;
      const hue = validateUint8(identityHue);
      const saturation = validateUint8(identitySaturation);
      const allowance = identityAllowanceRead.data ?? 0n;
      const handle = hasEnteredPaymentHandle ? validatePaymentHandle(paymentHandle) : '';

      if (selectedIdentityFeeRead === undefined || allowance < selectedIdentityFee) {
        const approveHash = await tx.execute(t('ser9Approve'), {
          address: contracts.ser9Proxy,
          abi: ser9Abi,
          functionName: 'approve',
          args: [contracts.identityProxy, maxUint256],
        });

        if (!approveHash) {
          return undefined;
        }

        if (!publicClient) {
          throw new Error('UNKNOWN');
        }

        await publicClient.waitForTransactionReceipt({ hash: approveHash });
        await queryClient.invalidateQueries();
      }

      if (handle) {
        await ensureHandleRegistrationReady();

        return await tx.execute(t('mintIdentityWithHandle'), {
          address: contracts.identityProxy,
          abi: identityAbi,
          functionName: 'mintIdentityWithHandle',
          args: [name, bio, entityTypeValue, hue, saturation, handle],
        });
      }

      return await tx.execute(t('mintIdentity'), {
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'mintIdentity',
        args: [name, bio, entityTypeValue, hue, saturation],
      });
    } catch (error) {
      setFormError(mapLocalError(error));
      return undefined;
    }
  }

  async function runSetPaymentHandleFlow() {
    resetErrors();

    if (!hasIdentity) {
      setFormError(t('identityRequired'));
      return undefined;
    }

    try {
      const handle = validatePaymentHandle(paymentHandle);
      await ensureHandleRegistrationReady();

      return await tx.execute(t('setPaymentHandle'), {
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'setHandle',
        args: [identityTokenId, handle],
      });
    } catch (error) {
      setFormError(mapLocalError(error));
      return undefined;
    }
  }

  async function runSetAvatarFlow() {
    resetErrors();

    if (!hasIdentity) {
      setFormError(t('identityRequired'));
      return undefined;
    }

    try {
      const hash = await tx.execute(t('saveAvatar'), {
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'setAvatar',
        args: [identityTokenId, avatarDraft],
      });

      if (hash) {
        await identityAvatarConfigRead.refetch();
        await identityTokenUriRead.refetch();
      }

      return hash;
    } catch (error) {
      setFormError(mapLocalError(error));
      return undefined;
    }
  }

  async function approvePaymentToken(tokenAddress: Address, amount: bigint, currentAllowance?: bigint) {
    if (currentAllowance !== undefined && currentAllowance >= amount) {
      return true;
    }

    const approveHash = await tx.execute(t('paymentApproveAsset'), {
      address: tokenAddress,
      abi: ser9Abi,
      functionName: 'approve',
      args: [contracts.identityProxy, maxUint256],
    });

    return Boolean(approveHash);
  }

  async function runDirectPaymentFlow() {
    resetErrors();

    if (!hasIdentity) {
      setFormError(t('identityRequired'));
      return undefined;
    }

    try {
      const token = resolvePaymentToken(paymentAssetType, paymentTokenAddress);
      const recipientHandle = validatePaymentHandle(paymentRecipientHandle);
      const amount = parsePositiveTokenAmount(paymentAmount);
      const memo = validatePaymentMemo(paymentMemo);

      if (paymentAssetType === 'erc20') {
        const approved = await approvePaymentToken(token, amount, directPaymentAllowanceRead.data);
        if (!approved) {
          return undefined;
        }
      }

      if (paymentAssetType === 'mon') {
        return await tx.executeSend(t('sendPayment'), {
          to: contracts.identityProxy,
          value: amount,
          data: encodeFunctionData({
            abi: identityAbi,
            functionName: 'payToHandle',
            args: [token, recipientHandle, amount, memo],
          }),
        });
      }

      return await tx.execute(t('sendPayment'), {
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'payToHandle',
        args: [token, recipientHandle, amount, memo],
      });
    } catch (error) {
      setFormError(mapLocalError(error));
      return undefined;
    }
  }

  async function runCreatePaymentRequestFlow() {
    resetErrors();

    if (!hasIdentity) {
      setFormError(t('identityRequired'));
      return undefined;
    }

    try {
      const token = resolvePaymentToken(requestAssetType, requestTokenAddress);
      const payerHandle = validatePaymentHandle(requestPayerHandle);
      const amount = parsePositiveTokenAmount(requestAmount);
      const dueAt = parsePaymentDueAt(requestDueAt);
      const memo = validatePaymentMemo(requestMemo);

      return await tx.execute(t('createPaymentRequest'), {
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'createPaymentRequest',
        args: [payerHandle, token, amount, dueAt, memo],
      });
    } catch (error) {
      setFormError(mapLocalError(error));
      return undefined;
    }
  }

  async function runPayPaymentRequestFlow(request: PaymentRequestValue) {
    resetErrors();

    try {
      if (request.token !== zeroAddress) {
        const allowance = await publicClient?.readContract({
          address: request.token,
          abi: ser9Abi,
          functionName: 'allowance',
          args: [addressForReads, contracts.identityProxy],
        });

        const approved = await approvePaymentToken(request.token, request.amount, allowance);
        if (!approved) {
          return undefined;
        }
      }

      if (request.token === zeroAddress) {
        return await tx.executeSend(t('payPaymentRequest'), {
          to: contracts.identityProxy,
          value: request.amount,
          data: encodeFunctionData({
            abi: identityAbi,
            functionName: 'payPaymentRequest',
            args: [request.id],
          }),
        });
      }

      return await tx.execute(t('payPaymentRequest'), {
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'payPaymentRequest',
        args: [request.id],
      });
    } catch (error) {
      setFormError(mapLocalError(error));
      return undefined;
    }
  }

  async function runCancelPaymentRequestFlow(requestId: bigint) {
    return await runWrite('cancelPaymentRequest', () => ({
      address: contracts.identityProxy,
      abi: identityAbi,
      functionName: 'cancelPaymentRequest',
      args: [requestId],
    }));
  }

  async function runSignDelegatedPaymentFlow(request: PaymentRequestValue, deadlineMinutes: number) {
    resetErrors();

    if (!normalizedConnectedAddress) {
      setFormError(t('connectHint'));
      return undefined;
    }

    try {
      const nonce = await publicClient?.readContract({
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'paymentNonces',
        args: [normalizedConnectedAddress],
      });
      if (typeof nonce !== 'bigint') {
        throw new Error('NONCE_FETCH_FAILED');
      }

      const minutes = Number.isFinite(deadlineMinutes) && deadlineMinutes > 0 ? deadlineMinutes : 60;
      const deadline = BigInt(Math.floor(Date.now() / 1000) + Math.floor(minutes * 60));

      const signature = await signTypedDataAsync({
        domain: {
          name: 'Series9Identity',
          version: '1',
          chainId: networkConfig.chainId,
          verifyingContract: contracts.identityProxy,
        },
        types: {
          PayPaymentRequestAuthorization: [
            { name: 'requestId', type: 'uint256' },
            { name: 'nonce', type: 'uint256' },
            { name: 'deadline', type: 'uint256' },
          ],
        },
        primaryType: 'PayPaymentRequestAuthorization',
        message: {
          requestId: request.id,
          nonce,
          deadline,
        },
      });

      setDelegatedSignatureOutput({
        requestId: request.id.toString(),
        nonce: nonce.toString(),
        deadline: deadline.toString(),
        signature,
        signer: normalizedConnectedAddress,
      });
      return signature;
    } catch (error) {
      setFormError(mapLocalError(error));
      return undefined;
    }
  }

  async function runRelayPaymentFlow(rawPayload: string) {
    resetErrors();

    try {
      const trimmed = rawPayload.trim();
      if (trimmed.length === 0) {
        throw new Error('EMPTY_RELAY_PAYLOAD');
      }
      const parsed = JSON.parse(trimmed) as Partial<{
        requestId: string | number;
        nonce: string | number;
        deadline: string | number;
        signature: string;
      }>;

      if (
        parsed.requestId === undefined ||
        parsed.nonce === undefined ||
        parsed.deadline === undefined ||
        typeof parsed.signature !== 'string' ||
        !isHex(parsed.signature as Hex)
      ) {
        throw new Error('INVALID_RELAY_PAYLOAD');
      }

      const requestId = BigInt(parsed.requestId);
      const nonce = BigInt(parsed.nonce);
      const deadline = BigInt(parsed.deadline);
      const signature = parsed.signature as Hex;

      const requestRaw = await publicClient?.readContract({
        address: contracts.identityProxy,
        abi: identityAbi,
        functionName: 'paymentRequest',
        args: [requestId],
      });
      const request = parsePaymentRequest(requestId, requestRaw);
      if (!request) {
        throw new Error('INVALID_RELAY_REQUEST');
      }

      if (request.token !== zeroAddress) {
        const allowance = await publicClient?.readContract({
          address: request.token,
          abi: ser9Abi,
          functionName: 'allowance',
          args: [addressForReads, contracts.identityProxy],
        });
        const approved = await approvePaymentToken(request.token, request.amount, allowance);
        if (!approved) {
          return undefined;
        }
      }

      const value = request.token === zeroAddress ? request.amount : 0n;

      return await tx.executeSend(t('payDelegatedPaymentRequest'), {
        to: contracts.identityProxy,
        value,
        data: encodeFunctionData({
          abi: identityAbi,
          functionName: 'payPaymentRequestWithSig',
          args: [requestId, nonce, deadline, signature],
        }),
      });
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
            <>
              <p className="muted">
                {t('ser9Balance')}: {formatTokenAmount(ser9BalanceRead.data)}
              </p>
              <p className="muted">
                {t('currentAllowance')}: {formatTokenAmount(ser9AllowanceRead.data)}
              </p>
            </>
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
          {isConnected ? (
            <p className="muted">
            </p>
          ) : (
            <p className="muted">{t('connectHint')}</p>
          )}
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
          {isConnected ? (
            <p className="muted">
              {t('monBalance')}: {formatTokenAmount(monBalanceRead.data?.value, monBalanceRead.data?.decimals)}
            </p>
          ) : (
            <p className="muted">{t('connectHint')}</p>
          )}
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

  function paymentAssetLabel(token: Address) {
    return token === zeroAddress ? 'MON' : shortenAddress(token);
  }

  function paymentStatusLabel(request: PaymentRequestValue) {
    const status = paymentRequestEffectiveStatus(request);
    if (status === PAYMENT_STATUS.paid) return t('paymentStatusPaid');
    if (status === PAYMENT_STATUS.cancelled) return t('paymentStatusCancelled');
    if (status === PAYMENT_STATUS.expired) return t('paymentStatusExpired');
    return t('paymentStatusPending');
  }

  function paymentDueLabel(request: PaymentRequestValue) {
    if (request.dueAt === 0n) {
      return '-';
    }
    return new Date(Number(request.dueAt) * 1000).toLocaleString(locale === 'ko' ? 'ko-KR' : 'en-US');
  }

  function renderPaymentRequestList(requests: PaymentRequestValue[], direction: 'incoming' | 'outgoing') {
    if (!hasIdentity) {
      return <p className="muted">{t('identityRequired')}</p>;
    }

    if (requests.length === 0) {
      return <p className="muted">{t('noPaymentRequests')}</p>;
    }

    return (
      <div className="payment-request-list">
        {requests.map((request) => {
          const effectiveStatus = paymentRequestEffectiveStatus(request);
          const isPending = effectiveStatus === PAYMENT_STATUS.pending;
          const canPay = direction === 'incoming' && isPending;
          const canCancel = isPending;

          return (
            <article key={request.id.toString()} className="payment-request-card">
              <div className="payment-request-head">
                <strong>#{request.id.toString()}</strong>
                <span className={`pill payment-status-${effectiveStatus}`}>{paymentStatusLabel(request)}</span>
              </div>
              <div className="metric-grid">
                <MetricCard label={t('paymentAsset')} value={paymentAssetLabel(request.token)} />
                <MetricCard label={t('amount')} value={formatTokenAmount(request.amount)} />
                <MetricCard label={t('paymentDueAt')} value={paymentDueLabel(request)} />
                <MetricCard
                  label={direction === 'incoming' ? t('paymentFrom') : t('paymentTo')}
                  value={`#${(direction === 'incoming' ? request.payeeTokenId : request.payerTokenId).toString()}`}
                />
              </div>
              {request.memo && <p className="muted payment-memo">{request.memo}</p>}
              <div className="status-actions status-actions-two">
                <button
                  type="button"
                  disabled={!canPay || !isConnected || onWrongChain || Boolean(identityPausedRead.data)}
                  onClick={() => void runPayPaymentRequestFlow(request)}
                >
                  {request.token === zeroAddress ? t('payWithMON') : t('payPaymentRequest')}
                </button>
                <button
                  type="button"
                  disabled={!canCancel || !isConnected || onWrongChain || Boolean(identityPausedRead.data)}
                  onClick={() => void runCancelPaymentRequestFlow(request.id)}
                >
                  {t('cancelPaymentRequest')}
                </button>
              </div>
              {canPay && (
                <div className="status-actions">
                  <button
                    type="button"
                    className="secondary"
                    disabled={!isConnected || onWrongChain || Boolean(identityPausedRead.data)}
                    onClick={() => {
                      const minutes = Number(delegatedSignatureDeadlineMinutes) || 60;
                      void runSignDelegatedPaymentFlow(request, minutes);
                      setDelegatedSignatureRequestId(request.id.toString());
                    }}
                  >
                    {t('signDelegatedPayment')}
                  </button>
                </div>
              )}
            </article>
          );
        })}
      </div>
    );
  }

  return (
    <div className="app-shell">
      <header className="hero">
        <div className="hero-copy">
          <div className="hero-topline">
            <nav className="page-nav">
              <a href="/" className={isHomePage ? 'active' : ''}>
                {t('navHome')}
              </a>
              <a href="/staking" className={isStakingPage ? 'active' : ''}>
                {t('navStaking')}
              </a>
              <a href="/tokens" className={isTokensListPage ? 'active' : ''}>
                {t('navTokens')}
              </a>
              <a href="/identity" className={isIdentityPage ? 'active' : ''}>
                {t('navIdentity')}
              </a>
              <a href="/payment" className={isPaymentPage ? 'active' : ''}>
                {t('navPayment')}
              </a>
            </nav>
            <div className="section-title hero-kicker">{t(isHomePage ? 'introKicker' : 'stakingOverview')}</div>
          </div>
          <div className="hero-copy-block">
            <h1>{t('appTitle')}</h1>
            <p className="hero-description">{t('appSubtitle')}</p>
          </div>
          <div className="hero-badges">
            <span className="hero-badge">
              {t('targetChain')}: {networkConfig.chainId}
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

      {isHomePage && (
        <>
          <section className="card intro-hero">
            <div className="section-title">{t('introKicker')}</div>
            <h2 className="intro-headline">{t('introHeadline')}</h2>
            <p className="muted intro-lead">{t('introLead')}</p>
          </section>

          <section className="intro-grid">
            <a className="card intro-card" href="/tokens">
              <span className="intro-card-index">01</span>
              <div className="section-title">{t('introTokenTag')}</div>
              <h3>{t('introTokenTitle')}</h3>
              <p className="muted">{t('introTokenDesc')}</p>
              <span className="intro-card-cta">{t('introTokenCta')} →</span>
            </a>
            <a className="card intro-card" href="/staking">
              <span className="intro-card-index">02</span>
              <div className="section-title">{t('introStakingTag')}</div>
              <h3>{t('introStakingTitle')}</h3>
              <p className="muted">{t('introStakingDesc')}</p>
              <span className="intro-card-cta">{t('introStakingCta')} →</span>
            </a>
            <a className="card intro-card" href="/identity">
              <span className="intro-card-index">03</span>
              <div className="section-title">{t('introIdentityTag')}</div>
              <h3>{t('introIdentityTitle')}</h3>
              <p className="muted">{t('introIdentityDesc')}</p>
              <span className="intro-card-cta">{t('introIdentityCta')} →</span>
            </a>
          </section>
        </>
      )}

      {isIdentityPage && (
        <>
          <section className="card">
            <div className="section-head section-head-highlight">
              <div>
                <div className="section-title section-title-inline">SERIES9 Identity</div>
                <h2>{t('identityPageTitle')}</h2>
              </div>
              <span className="pill">
                {t('paused')}: {identityPausedRead.data === undefined ? '-' : identityPausedRead.data ? t('yes') : t('no')}
              </span>
            </div>
            <p className="muted">{t('identityPageHint')}</p>
          </section>

          <section className="identity-layout">
            <form className="single-form identity-form" onSubmit={(event) => onSubmit(event, runMintIdentityFlow)}>
              <h3>{t('mintIdentity')}</h3>

              <label className="field-stack">
                <span>{t('identityName')}</span>
                <input
                  value={identityName}
                  onChange={(event) => setIdentityName(event.target.value)}
                  placeholder="SERIES9"
                  disabled={hasIdentity}
                />
                <small className={identityNameBytes > IDENTITY_NAME_MAX_BYTES ? 'error' : 'muted'}>
                  {identityNameBytes}/{IDENTITY_NAME_MAX_BYTES} bytes
                </small>
              </label>

              <label className="field-stack">
                <span>{t('identityBio')}</span>
                <textarea
                  value={identityBio}
                  onChange={(event) => setIdentityBio(event.target.value)}
                  placeholder={t('identityBioPlaceholder')}
                  disabled={hasIdentity}
                />
                <small className={identityBioBytes > IDENTITY_BIO_MAX_BYTES ? 'error' : 'muted'}>
                  {identityBioBytes}/{IDENTITY_BIO_MAX_BYTES} bytes
                </small>
              </label>

              <div className="field-stack">
                <span>{t('identityType')}</span>
                <div className="identity-type-row" role="group" aria-label={t('identityType')}>
                  <button
                    type="button"
                    className={identityEntityType === 'human' ? 'active' : ''}
                    onClick={() => setIdentityEntityType('human')}
                    disabled={hasIdentity}
                  >
                    {t('identityHuman')}
                  </button>
                  <button
                    type="button"
                    className={identityEntityType === 'ai' ? 'active' : ''}
                    onClick={() => setIdentityEntityType('ai')}
                    disabled={hasIdentity}
                  >
                    {t('identityAI')}
                  </button>
                </div>
              </div>

              <div className="slider-wrap">
                <div className="slider-head">
                  <label htmlFor="identity-hue">{t('identityHue')}</label>
                  <strong>{identityHue}</strong>
                </div>
                <input
                  id="identity-hue"
                  type="range"
                  min="0"
                  max="255"
                  value={identityHue}
                  disabled={hasIdentity}
                  onChange={(event) => setIdentityHue(Number(event.target.value))}
                />
              </div>

              <div className="slider-wrap">
                <div className="slider-head">
                  <label htmlFor="identity-saturation">{t('identitySaturation')}</label>
                  <strong>{identitySaturation}</strong>
                </div>
                <input
                  id="identity-saturation"
                  type="range"
                  min="0"
                  max="255"
                  value={identitySaturation}
                  disabled={hasIdentity}
                  onChange={(event) => setIdentitySaturation(Number(event.target.value))}
                />
              </div>

              <div className="metric-grid">
                <MetricCard label={t('identityMintFee')} value={`${formatTokenAmount(selectedIdentityFee)} SER9`} />
                <MetricCard label={t('identityAllowance')} value={`${formatTokenAmount(identityAllowanceRead.data)} SER9`} />
              </div>

              <label className="field-stack">
                <span>{t('paymentHandle')}</span>
                <input
                  value={paymentHandle}
                  onChange={(event) => setPaymentHandle(event.target.value)}
                  placeholder="series9-user"
                />
                <small className={paymentHandleBytes > 32 ? 'error' : 'muted'}>
                  {paymentHandleBytes}/32 bytes · a-z, 0-9, -
                </small>
              </label>

              <button type="submit" className="primary" disabled={!isConnected || onWrongChain || Boolean(identityPausedRead.data)}>
                {hasIdentity
                  ? t('setPaymentHandle')
                  : identityNeedsApproval
                    ? t('approveAndMintIdentity')
                    : hasEnteredPaymentHandle
                      ? t('mintIdentityWithHandle')
                      : t('mintIdentity')}
              </button>
              {!isConnected && <p className="muted">{t('connectHint')}</p>}
              {hasIdentity && <p className="success">{t('alreadyHasIdentity')}</p>}
              {legacyHandleReservationsFinalizedRead.data === false && (
                <p className="muted">{t('legacyHandlesPending')}</p>
              )}
            </form>

            <article className="status-card identity-preview-card">
              <div className="status-card-head">
                <div>
                  <div className="section-title section-title-inline">Identity</div>
                  <h2>{t('identityStatus')}</h2>
                </div>
                <span className="pill">{hasIdentity ? `#${identityTokenId.toString()}` : t('identityNotMinted')}</span>
              </div>

              <div className={`identity-avatar-preview ${hasIdentity && identityNftImageSrc ? 'identity-nft-preview' : ''}`}>
                {hasIdentity && identityNftImageSrc ? (
                  <img
                    className="identity-nft-image"
                    src={identityNftImageSrc}
                    alt={identityDisplayName}
                  />
                ) : (
                  <div className="identity-avatar-ring" style={{ borderColor: identityPreviewColor }}>
                    <div className="identity-avatar-core" style={{ background: identityPreviewColor }} />
                  </div>
                )}
                <div>
                  <strong>{identityDisplayName}</strong>
                  <span>{hasIdentity ? identityDisplayType : identityEntityType === 'ai' ? t('identityAI') : t('identityHuman')}</span>
                  {hasIdentity && !identityNftImageSrc && identityTokenUriRead.isLoading && (
                    <span>{t('identityNftLoading')}</span>
                  )}
                  {hasIdentity && identityTokenUriRead.isError && (
                    <span>{t('identityNftUnavailable')}</span>
                  )}
                </div>
              </div>

              <div className="metric-grid">
                <MetricCard label={t('identityTokenId')} value={hasIdentity ? identityTokenId.toString() : '-'} />
                <MetricCard label={t('paymentHandle')} value={hasIdentity ? currentIdentityHandle || '-' : '-'} />
                <MetricCard label={t('identityReputation')} value={hasIdentity ? (identityReputationRead.data?.toString() ?? '-') : '-'} />
                <MetricCard label={t('identityRewards')} value={formatRewardAmount(identityPendingRewardsRead.data)} />
                <MetricCard label={t('identityStakingRewards')} value={formatRewardAmount(identityPendingStakingRewardsRead.data)} />
              </div>

              <div className="status-actions status-actions-two">
                <button
                  type="button"
                  disabled={!isConnected || onWrongChain || !hasIdentity || Boolean(identityPausedRead.data) || (identityPendingRewardsRead.data ?? 0n) === 0n}
                  onClick={() => void runWrite('claimIdentityRewards', () => ({
                    address: contracts.identityProxy,
                    abi: identityAbi,
                    functionName: 'claimNFTRewards',
                    args: [],
                  }))}
                >
                  {t('claimIdentityRewards')}
                </button>
                <button
                  type="button"
                  disabled={!isConnected || onWrongChain || Boolean(identityPausedRead.data) || (identityPendingStakingRewardsRead.data ?? 0n) === 0n}
                  onClick={() => void runWrite('collectIdentityRewards', () => ({
                    address: contracts.identityProxy,
                    abi: identityAbi,
                    functionName: 'collectStakingRewards',
                    args: [],
                  }))}
                >
                  {t('collectIdentityRewards')}
                </button>
              </div>
            </article>
          </section>

          {hasIdentity && (
            <section className="card avatar-card">
              <AvatarBuilder
                config={avatarDraft}
                onChange={setAvatarDraft}
                hue={identityHue}
                disabled={!isConnected || onWrongChain || Boolean(identityPausedRead.data)}
                busy={tx.isWalletPrompt || tx.isConfirming}
                dirty={avatarDirty}
                onSave={() => void runSetAvatarFlow()}
                title={t('avatarBuilderTitle')}
                hint={t('avatarBuilderHint')}
                saveLabel={t('saveAvatar')}
                resolveLabel={(key) => t(key as MessageKey)}
              />
            </section>
          )}
        </>
      )}

      {isPaymentPage && (
        <>
          <section className="card">
            <div className="section-head section-head-highlight">
              <div>
                <div className="section-title section-title-inline">SERIES9 Payment</div>
                <h2>{t('paymentPageTitle')}</h2>
              </div>
              <span className="pill">
                {t('paused')}: {identityPausedRead.data === undefined ? '-' : identityPausedRead.data ? t('yes') : t('no')}
              </span>
            </div>
            <p className="muted">{t('paymentPageHint')}</p>
          </section>

          <section className="payment-layout">
            <form className="single-form identity-form" onSubmit={(event) => onSubmit(event, runSetPaymentHandleFlow)}>
              <h3>{t('paymentHandle')}</h3>
              <div className="metric-grid">
                <MetricCard label={t('identityTokenId')} value={hasIdentity ? identityTokenId.toString() : '-'} />
                <MetricCard label={t('currentPaymentHandle')} value={hasIdentity ? currentIdentityHandle || '-' : '-'} />
              </div>
              <label className="field-stack">
                <span>{t('paymentHandle')}</span>
                <input
                  value={paymentHandle}
                  onChange={(event) => setPaymentHandle(event.target.value)}
                  placeholder="series9-user"
                  disabled={!hasIdentity}
                />
                <small className={paymentHandleBytes > 32 ? 'error' : 'muted'}>
                  {paymentHandleBytes}/32 bytes · a-z, 0-9, -
                </small>
              </label>
              <button type="submit" className="primary" disabled={!isConnected || onWrongChain || !hasIdentity || Boolean(identityPausedRead.data)}>
                {t('setPaymentHandle')}
              </button>
              {legacyHandleReservationsFinalizedRead.data === false && (
                <p className="muted">{t('legacyHandlesPending')}</p>
              )}
              {!hasIdentity && <p className="muted">{t('identityRequired')}</p>}
            </form>

            <form className="single-form identity-form" onSubmit={(event) => onSubmit(event, runDirectPaymentFlow)}>
              <h3>{t('sendPayment')}</h3>
              <div className="identity-type-row" role="group" aria-label={t('paymentAsset')}>
                <button type="button" className={paymentAssetType === 'mon' ? 'active' : ''} onClick={() => setPaymentAssetType('mon')}>
                  MON
                </button>
                <button type="button" className={paymentAssetType === 'erc20' ? 'active' : ''} onClick={() => setPaymentAssetType('erc20')}>
                  ERC20
                </button>
              </div>
              {paymentAssetType === 'erc20' && (
                <label className="field-stack">
                  <span>{t('tokenAddress')}</span>
                  <input value={paymentTokenAddress} onChange={(event) => setPaymentTokenAddress(event.target.value)} />
                </label>
              )}
              <label className="field-stack">
                <span>{t('recipientHandle')}</span>
                <input value={paymentRecipientHandle} onChange={(event) => setPaymentRecipientHandle(event.target.value)} placeholder="receiver" />
              </label>
              <label className="field-stack">
                <span>{t('amount')}</span>
                <input value={paymentAmount} onChange={(event) => setPaymentAmount(event.target.value)} placeholder="0.0" />
              </label>
              <label className="field-stack">
                <span>{t('paymentMemo')}</span>
                <textarea value={paymentMemo} onChange={(event) => setPaymentMemo(event.target.value)} placeholder={t('paymentMemoPlaceholder')} />
                <small className={paymentMemoBytes > PAYMENT_MEMO_MAX_BYTES ? 'error' : 'muted'}>
                  {paymentMemoBytes}/{PAYMENT_MEMO_MAX_BYTES} bytes
                </small>
              </label>
              {paymentAssetType === 'erc20' && (
                <MetricCard label={t('identityAllowance')} value={`${formatTokenAmount(directPaymentAllowanceRead.data)} ERC20`} />
              )}
              <button type="submit" className="primary" disabled={!isConnected || onWrongChain || !hasIdentity || Boolean(identityPausedRead.data)}>
                {directPaymentNeedsApproval ? t('approveAndSendPayment') : t('sendPayment')}
              </button>
            </form>

            <form className="single-form identity-form" onSubmit={(event) => onSubmit(event, runCreatePaymentRequestFlow)}>
              <h3>{t('createPaymentRequest')}</h3>
              <div className="identity-type-row" role="group" aria-label={t('paymentAsset')}>
                <button type="button" className={requestAssetType === 'mon' ? 'active' : ''} onClick={() => setRequestAssetType('mon')}>
                  MON
                </button>
                <button type="button" className={requestAssetType === 'erc20' ? 'active' : ''} onClick={() => setRequestAssetType('erc20')}>
                  ERC20
                </button>
              </div>
              {requestAssetType === 'erc20' && (
                <label className="field-stack">
                  <span>{t('tokenAddress')}</span>
                  <input value={requestTokenAddress} onChange={(event) => setRequestTokenAddress(event.target.value)} />
                </label>
              )}
              <label className="field-stack">
                <span>{t('payerHandle')}</span>
                <input value={requestPayerHandle} onChange={(event) => setRequestPayerHandle(event.target.value)} placeholder="payer" />
              </label>
              <label className="field-stack">
                <span>{t('amount')}</span>
                <input value={requestAmount} onChange={(event) => setRequestAmount(event.target.value)} placeholder="0.0" />
              </label>
              <label className="field-stack">
                <span>{t('paymentDueAt')}</span>
                <input type="datetime-local" value={requestDueAt} onChange={(event) => setRequestDueAt(event.target.value)} />
              </label>
              <label className="field-stack">
                <span>{t('paymentMemo')}</span>
                <textarea value={requestMemo} onChange={(event) => setRequestMemo(event.target.value)} placeholder={t('paymentMemoPlaceholder')} />
                <small className={requestMemoBytes > PAYMENT_MEMO_MAX_BYTES ? 'error' : 'muted'}>
                  {requestMemoBytes}/{PAYMENT_MEMO_MAX_BYTES} bytes
                </small>
              </label>
              {requestAssetType === 'erc20' && (
                <MetricCard label={t('identityAllowance')} value={`${formatTokenAmount(requestPaymentAllowanceRead.data)} ERC20`} />
              )}
              <button type="submit" className="primary" disabled={!isConnected || onWrongChain || !hasIdentity || Boolean(identityPausedRead.data)}>
                {requestPaymentNeedsApproval ? t('createPaymentRequest') : t('createPaymentRequest')}
              </button>
            </form>
          </section>

          <section className="payment-requests-grid">
            <article className="card">
              <div className="section-head section-head-highlight">
                <div>
                  <div className="section-title section-title-inline">{t('incomingPaymentRequests')}</div>
                  <h2>{t('incomingPaymentRequests')}</h2>
                </div>
              </div>
              {renderPaymentRequestList(incomingPaymentRequests, 'incoming')}
            </article>

            <article className="card">
              <div className="section-head section-head-highlight">
                <div>
                  <div className="section-title section-title-inline">{t('outgoingPaymentRequests')}</div>
                  <h2>{t('outgoingPaymentRequests')}</h2>
                </div>
              </div>
              {renderPaymentRequestList(outgoingPaymentRequests, 'outgoing')}
            </article>
          </section>

          <section className="payment-requests-grid">
            <article className="card">
              <div className="section-head section-head-highlight">
                <div>
                  <div className="section-title section-title-inline">{t('delegatedPaymentSign')}</div>
                  <h2>{t('delegatedPaymentSign')}</h2>
                </div>
              </div>
              <p className="muted">{t('delegatedPaymentSignHint')}</p>
              <div className="form-row">
                <label>
                  <span>{t('delegatedSignatureDeadlineMinutes')}</span>
                  <input
                    type="number"
                    min={1}
                    value={delegatedSignatureDeadlineMinutes}
                    onChange={(event) => setDelegatedSignatureDeadlineMinutes(event.target.value)}
                  />
                </label>
              </div>
              {delegatedSignatureOutput && (
                <div className="metric-grid">
                  <MetricCard label={t('delegatedSignatureRequestId')} value={`#${delegatedSignatureOutput.requestId}`} />
                  <MetricCard label={t('delegatedSignatureNonce')} value={delegatedSignatureOutput.nonce} />
                  <MetricCard
                    label={t('delegatedSignatureDeadline')}
                    value={new Date(Number(delegatedSignatureOutput.deadline) * 1000).toLocaleString()}
                  />
                  <MetricCard
                    label={t('delegatedSignatureSigner')}
                    value={shortenAddress(delegatedSignatureOutput.signer, 6)}
                  />
                </div>
              )}
              {delegatedSignatureOutput && (
                <>
                  <textarea
                    readOnly
                    value={JSON.stringify(
                      {
                        requestId: delegatedSignatureOutput.requestId,
                        nonce: delegatedSignatureOutput.nonce,
                        deadline: delegatedSignatureOutput.deadline,
                        signature: delegatedSignatureOutput.signature,
                      },
                      null,
                      2,
                    )}
                  />
                  <div className="status-actions">
                    <button
                      type="button"
                      className="secondary"
                      onClick={() => {
                        void navigator.clipboard
                          ?.writeText(
                            JSON.stringify({
                              requestId: delegatedSignatureOutput.requestId,
                              nonce: delegatedSignatureOutput.nonce,
                              deadline: delegatedSignatureOutput.deadline,
                              signature: delegatedSignatureOutput.signature,
                            }),
                          )
                          .catch(() => undefined);
                      }}
                    >
                      {t('copyDelegatedSignature')}
                    </button>
                  </div>
                </>
              )}
              {!delegatedSignatureOutput && (
                <p className="muted">
                  {delegatedSignatureRequestId
                    ? t('delegatedPaymentSignPrompt')
                    : t('delegatedPaymentSignNoRequest')}
                </p>
              )}
            </article>

            <article className="card">
              <div className="section-head section-head-highlight">
                <div>
                  <div className="section-title section-title-inline">{t('delegatedPaymentRelay')}</div>
                  <h2>{t('delegatedPaymentRelay')}</h2>
                </div>
              </div>
              <p className="muted">{t('delegatedPaymentRelayHint')}</p>
              <textarea
                value={relayPaymentPayload}
                onChange={(event) => setRelayPaymentPayload(event.target.value)}
                placeholder={t('delegatedPaymentRelayPlaceholder')}
              />
              <div className="status-actions">
                <button
                  type="button"
                  className="primary"
                  disabled={!isConnected || onWrongChain || Boolean(identityPausedRead.data)}
                  onClick={() => void runRelayPaymentFlow(relayPaymentPayload)}
                >
                  {t('payDelegatedPaymentRequest')}
                </button>
              </div>
            </article>
          </section>
        </>
      )}

      {isTokensListPage && (
        <>

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
              <MetricCard label={t('rewardRatePerBlock')} value={formatTokenAmount(rewardRateRead.data)} />
              <MetricCard label={t('tokenCreationFee')} value={formatTokenAmount(creationFeeRead.data)} />
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

      {isStakingPage && (
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
                <MetricCard label={t('ser9UnstakingAmount')} value={formatTokenAmount(pendingSer9UnstakeSummary?.totalAmount)} />
                {pendingSer9UnstakeRemainingTime && (
                  <MetricCard label={t('unstakeRemainingTime')} value={pendingSer9UnstakeRemainingTime} />
                )}
              </div>
              <div className="status-actions status-actions-two">
                <button type="button" onClick={() => setActiveActionModal('ser9Stake')} disabled={!isConnected || onWrongChain}>
                  {t('stake')}
                </button>

                <button
                  type="button"
                  onClick={(event) => {
                    if (firstClaimableSer9UnstakeRequestId !== null) {
                      onSubmit(event, () => runWrite('claimUnstakedSer9', () => ({
                        address: contracts.stakingProxy,
                        abi: stakingAbi,
                        functionName: 'claimUnstaked' as const,
                        args: [firstClaimableSer9UnstakeRequestId] as const,
                      })));
                      return;
                    }

                    setActiveActionModal('ser9Unstake');
                  }}
                  disabled={!isConnected || onWrongChain}
                >
                  {firstClaimableSer9UnstakeRequestId !== null ? t('claimUnstakedSer9') : t('unstake')}
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
                {pendingMonadUnstakeSummary.totalAmount > 0n && (
                  <MetricCard
                    label={t('unstakingAmount')}
                    value={formatTokenAmount(pendingMonadUnstakeSummary.totalAmount)}
                  />
                )}
                {pendingMonadUnstakeRemainingTime && (
                  <MetricCard label={t('unstakeRemainingTime')} value={pendingMonadUnstakeRemainingTime} />
                )}
              </div>
              <div className="status-actions status-actions-two">
                <button type="button" onClick={() => setActiveActionModal('monadStake')} disabled={!isConnected || onWrongChain}>
                  {t('monadStake')}
                </button>

                <button
                  type="button"
                  onClick={(event) => {
                    if (firstClaimableMonadUnstakeRequestId !== null) {
                      onSubmit(event, () => runWrite('claimUnstakedMonad', () => ({
                        address: contracts.stakingProxy,
                        abi: stakingAbi,
                        functionName: 'claimUnstakedMonad' as const,
                        args: [firstClaimableMonadUnstakeRequestId] as const,
                      })));
                      return;
                    }

                    setActiveActionModal('monadUnstake');
                  }}
                  disabled={!isConnected || onWrongChain}
                >
                  {firstClaimableMonadUnstakeRequestId !== null ? t('claimUnstakedMonad') : t('requestMonadUnstake')}
                </button>

              </div>
            </article>

            <article className="status-card">
              <div className="status-card-head">
                <div>
                  <div className="section-title section-title-inline">SER9</div>
                  <h2>{t('rewardsStatus')}</h2>
                </div>
                <span className="pill">{t('rewardsStatus')}</span>
              </div>
              <p className="status-card-copy muted">{t('rewardsDescription')}</p>
              <div className="metric-grid">
                <MetricCard label={t('totalClaimableRewards')} value={formatRewardAmount(totalClaimableRewards)} />
                <MetricCard label={t('ser9UnclaimedStakingRewards')} value={formatRewardAmount(ser9ClaimableRewards)} />
                <MetricCard label={t('monadSer9UnclaimedRewards')} value={formatRewardAmount(monadClaimableRewards)} />
              </div>
              <div className="status-actions status-actions-single">
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
          </section>

        </>
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
