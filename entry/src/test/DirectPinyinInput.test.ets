import { describe, it, expect } from '@ohos/hypium';
import { appendDirectPinyinRawInput, backspaceDirectPinyinRawInput } from '../main/ets/ime/session/DirectPinyinInput';

export default function directPinyinInputTest() {
  describe('DirectPinyinInput', () => {
    it('appendMultipleLettersUsingRawInputOnly', 0, () => {
      let input = appendDirectPinyinRawInput('', 'n', 32);
      expect(input).assertEqual('n');

      input = appendDirectPinyinRawInput(input ?? '', 'i', 32);
      expect(input).assertEqual('ni');

      input = appendDirectPinyinRawInput(input ?? '', 'H', 32);
      expect(input).assertEqual('nih');
    });

    it('respectCompositionLengthLimit', 0, () => {
      let input = appendDirectPinyinRawInput('ni', 'h', 2);
      expect(input === undefined).assertTrue();
    });

    it('backspaceOnlyMutatesRawInputBuffer', 0, () => {
      expect(backspaceDirectPinyinRawInput('nihao')).assertEqual('niha');
      expect(backspaceDirectPinyinRawInput('n')).assertEqual('');
      expect(backspaceDirectPinyinRawInput('')).assertEqual('');
    });
  });
}