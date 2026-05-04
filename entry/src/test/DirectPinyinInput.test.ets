import { describe, it, expect } from '@ohos/hypium';
import {
  appendDirectPinyinRawInput,
  backspaceDirectPinyinRawInput,
  formatDirectPinyinRawInput
} from '../main/ets/ime/session/DirectPinyinInput';

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

    it('formatRawPinyinWithSyllableSeparators', 0, () => {
      expect(formatDirectPinyinRawInput('guojia')).assertEqual('guo\'jia');
      expect(formatDirectPinyinRawInput('xian')).assertEqual('xian');
      expect(formatDirectPinyinRawInput('shanghai')).assertEqual('shang\'hai');
      expect(formatDirectPinyinRawInput('guoj')).assertEqual('guo\'j');
      expect(formatDirectPinyinRawInput('NIHAO')).assertEqual('ni\'hao');
      expect(formatDirectPinyinRawInput('xi\'an')).assertEqual('xi\'an');
    });
  });
}
