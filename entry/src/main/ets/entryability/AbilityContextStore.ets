import { common } from '@kit.AbilityKit';

let entryAbilityContext: common.UIAbilityContext | undefined = undefined;

export function rememberEntryAbilityContext(context: common.UIAbilityContext): void {
  entryAbilityContext = context;
}

export function forgetEntryAbilityContext(): void {
  entryAbilityContext = undefined;
}

export function getEntryAbilityContext(): common.UIAbilityContext | undefined {
  return entryAbilityContext;
}