import { BuiltinModelCatalog, BuiltinModelPreset, BuiltinModelProvider } from '../common/ImeTypes';

export interface ResolvedBuiltinModelSelection {
  provider: BuiltinModelProvider;
  preset: BuiltinModelPreset;
}

// Copied from design/config/builtin-models.json so the runtime can consume the
// catalog directly without depending on design-time assets.
const BUILTIN_MODEL_CATALOG: BuiltinModelCatalog = {
  version: 1,
  protocols: [
    'openai-compatible',
    'anthropic-compatible'
  ],
  providers: [
    {
      providerId: 'kimi',
      providerName: '月之暗面',
      models: [
        {
          presetId: 'kimi-default',
          displayName: 'Kimi',
          apiModel: 'kimi-k2.5',
          protocol: 'openai-compatible',
          endpoint: 'https://api.moonshot.cn/v1',
          enabled: true
        },
        {
          presetId: 'kimi-code-default',
          displayName: 'Kimi-Code',
          apiModel: 'kimi-for-coding',
          protocol: 'anthropic-compatible',
          endpoint: 'https://api.kimi.com/coding/v1',
          enabled: true
        }
      ]
    },
    {
      providerId: 'z-ai',
      providerName: '智谱',
      models: [
        {
          presetId: 'z-ai-glm-4-plus',
          displayName: 'GLM-4-Plus',
          apiModel: 'glm-4-plus',
          protocol: 'openai-compatible',
          endpoint: 'https://open.bigmodel.cn/api/paas/v4',
          enabled: true
        },
        {
          presetId: 'z-ai-glm-4-flash',
          displayName: 'GLM-4-Flash',
          apiModel: 'glm-4-flash',
          protocol: 'openai-compatible',
          endpoint: 'https://open.bigmodel.cn/api/paas/v4',
          enabled: true
        },
        {
          presetId: 'z-ai-glm-4-5',
          displayName: 'GLM-4.5',
          apiModel: 'glm-4.5',
          protocol: 'openai-compatible',
          endpoint: 'https://open.bigmodel.cn/api/paas/v4',
          enabled: true
        }
      ]
    }
  ]
};

export function listBuiltinModelProviders(): BuiltinModelProvider[] {
  let providers: BuiltinModelProvider[] = [];
  for (let index = 0; index < BUILTIN_MODEL_CATALOG.providers.length; index++) {
    providers.push(cloneBuiltinModelProvider(BUILTIN_MODEL_CATALOG.providers[index]));
  }
  return providers;
}

export function getDefaultBuiltinModelSelection(): ResolvedBuiltinModelSelection {
  for (let providerIndex = 0; providerIndex < BUILTIN_MODEL_CATALOG.providers.length; providerIndex++) {
    let provider = BUILTIN_MODEL_CATALOG.providers[providerIndex];
    let preset = findFirstEnabledPreset(provider);
    if (preset) {
      return {
        provider: cloneBuiltinModelProvider(provider),
        preset: cloneBuiltinModelPreset(preset)
      };
    }
  }
  let fallbackProvider: BuiltinModelProvider = {
    providerId: 'local-fallback',
    providerName: '本地润色',
    models: [
      {
        presetId: 'local-fallback-default',
        displayName: 'Local',
        apiModel: 'local-fallback',
        protocol: 'openai-compatible',
        endpoint: '',
        enabled: true
      }
    ]
  };
  return {
    provider: cloneBuiltinModelProvider(fallbackProvider),
    preset: cloneBuiltinModelPreset(fallbackProvider.models[0])
  };
}

export function resolveBuiltinModelSelection(providerId?: string, presetId?: string): ResolvedBuiltinModelSelection {
  let normalizedProviderId = typeof providerId === 'string' ? providerId.trim() : '';
  let normalizedPresetId = typeof presetId === 'string' ? presetId.trim() : '';
  let matchedProvider = findProviderById(normalizedProviderId);
  if (matchedProvider) {
    let matchedPreset = findPresetById(matchedProvider, normalizedPresetId);
    if (matchedPreset && matchedPreset.enabled) {
      return {
        provider: cloneBuiltinModelProvider(matchedProvider),
        preset: cloneBuiltinModelPreset(matchedPreset)
      };
    }
    let fallbackPreset = findFirstEnabledPreset(matchedProvider);
    if (fallbackPreset) {
      return {
        provider: cloneBuiltinModelProvider(matchedProvider),
        preset: cloneBuiltinModelPreset(fallbackPreset)
      };
    }
  }

  if (normalizedPresetId.length > 0) {
    for (let providerIndex = 0; providerIndex < BUILTIN_MODEL_CATALOG.providers.length; providerIndex++) {
      let provider = BUILTIN_MODEL_CATALOG.providers[providerIndex];
      let matchedPreset = findPresetById(provider, normalizedPresetId);
      if (matchedPreset && matchedPreset.enabled) {
        return {
          provider: cloneBuiltinModelProvider(provider),
          preset: cloneBuiltinModelPreset(matchedPreset)
        };
      }
    }
  }

  return getDefaultBuiltinModelSelection();
}

function findProviderById(providerId: string): BuiltinModelProvider | undefined {
  if (providerId.length === 0) {
    return undefined;
  }
  for (let index = 0; index < BUILTIN_MODEL_CATALOG.providers.length; index++) {
    let provider = BUILTIN_MODEL_CATALOG.providers[index];
    if (provider.providerId === providerId) {
      return provider;
    }
  }
  return undefined;
}

function findPresetById(provider: BuiltinModelProvider, presetId: string): BuiltinModelPreset | undefined {
  if (presetId.length === 0) {
    return undefined;
  }
  for (let index = 0; index < provider.models.length; index++) {
    let preset = provider.models[index];
    if (preset.presetId === presetId) {
      return preset;
    }
  }
  return undefined;
}

function findFirstEnabledPreset(provider: BuiltinModelProvider): BuiltinModelPreset | undefined {
  for (let index = 0; index < provider.models.length; index++) {
    let preset = provider.models[index];
    if (preset.enabled) {
      return preset;
    }
  }
  return provider.models.length > 0 ? provider.models[0] : undefined;
}

function cloneBuiltinModelProvider(source: BuiltinModelProvider): BuiltinModelProvider {
  return {
    providerId: source.providerId,
    providerName: source.providerName,
    models: source.models.map((preset: BuiltinModelPreset): BuiltinModelPreset => {
      return cloneBuiltinModelPreset(preset);
    })
  };
}

function cloneBuiltinModelPreset(source: BuiltinModelPreset): BuiltinModelPreset {
  return {
    presetId: source.presetId,
    displayName: source.displayName,
    apiModel: source.apiModel,
    protocol: source.protocol,
    endpoint: source.endpoint,
    enabled: source.enabled
  };
}
