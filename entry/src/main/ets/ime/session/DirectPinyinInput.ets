export function appendDirectPinyinRawInput(rawInput: string, letter: string, maxCompositionLength: number): string | undefined {
  let nextInput = `${rawInput}${letter.toLowerCase()}`;
  if (maxCompositionLength > 0 && nextInput.length > maxCompositionLength) {
    return undefined;
  }
  return nextInput;
}

export function backspaceDirectPinyinRawInput(rawInput: string): string {
  if (rawInput.length === 0) {
    return '';
  }
  return rawInput.substring(0, rawInput.length - 1);
}