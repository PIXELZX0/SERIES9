import { useMemo } from 'react'
import {
  AVATAR_OPTIONS,
  AVATAR_SLOTS,
  type AvatarConfig,
  type AvatarSlot,
  MAX_AVATAR_SLOT_OPTION,
  avatarSvgDataUri,
} from '../utils/avatarRenderer'

type SlotLabelKey =
  | 'avatarSlotSkinTone'
  | 'avatarSlotHairStyle'
  | 'avatarSlotHairColor'
  | 'avatarSlotEyes'
  | 'avatarSlotMouth'
  | 'avatarSlotOutfit'
  | 'avatarSlotAccessory'
  | 'avatarSlotBackground'

const SLOT_LABEL_KEYS: Record<AvatarSlot, SlotLabelKey> = {
  skinTone: 'avatarSlotSkinTone',
  hairStyle: 'avatarSlotHairStyle',
  hairColor: 'avatarSlotHairColor',
  eyes: 'avatarSlotEyes',
  mouth: 'avatarSlotMouth',
  outfit: 'avatarSlotOutfit',
  accessory: 'avatarSlotAccessory',
  background: 'avatarSlotBackground',
}

export type AvatarBuilderProps = {
  config: AvatarConfig
  onChange: (next: AvatarConfig) => void
  hue: number
  disabled?: boolean
  busy?: boolean
  dirty?: boolean
  onSave?: () => void
  title: string
  hint: string
  saveLabel: string
  resolveLabel: (key: SlotLabelKey) => string
}

export function AvatarBuilder({
  config,
  onChange,
  hue,
  disabled,
  busy,
  dirty,
  onSave,
  title,
  hint,
  saveLabel,
  resolveLabel,
}: AvatarBuilderProps) {
  const previewUri = useMemo(() => avatarSvgDataUri(config, hue), [config, hue])

  function setSlot(slot: AvatarSlot, value: number) {
    onChange({ ...config, [slot]: value })
  }

  return (
    <div className="avatar-builder">
      <header className="avatar-builder-head">
        <div>
          <div className="section-title section-title-inline">Avatar</div>
          <h3>{title}</h3>
          <p className="muted">{hint}</p>
        </div>
        <div className="avatar-builder-preview">
          <img src={previewUri} alt="Avatar preview" width={136} height={136} />
        </div>
      </header>

      <div className="avatar-builder-slots">
        {AVATAR_SLOTS.map((slot) => {
          const labels = AVATAR_OPTIONS[slot]
          const currentValue = config[slot]
          return (
            <div key={slot} className="avatar-slot-row">
              <div className="avatar-slot-label">{resolveLabel(SLOT_LABEL_KEYS[slot])}</div>
              <div className="avatar-slot-options" role="radiogroup">
                {Array.from({ length: MAX_AVATAR_SLOT_OPTION + 1 }, (_, i) => (
                  <button
                    key={i}
                    type="button"
                    role="radio"
                    aria-checked={currentValue === i}
                    className={`avatar-slot-chip ${currentValue === i ? 'active' : ''}`}
                    disabled={disabled}
                    onClick={() => setSlot(slot, i)}
                  >
                    <span className="avatar-slot-chip-index">{i}</span>
                    <span className="avatar-slot-chip-label">{labels[i] ?? String(i)}</span>
                  </button>
                ))}
              </div>
            </div>
          )
        })}
      </div>

      {onSave && (
        <div className="avatar-builder-actions">
          <button
            type="button"
            className="primary"
            disabled={disabled || busy || !dirty}
            onClick={onSave}
          >
            {saveLabel}
          </button>
        </div>
      )}
    </div>
  )
}
