import localUnitTest from './LocalUnit.test';
import pinyinNineKeyEngineTest from './PinyinNineKeyEngine.test';

export default function testsuite() {
  localUnitTest();
  pinyinNineKeyEngineTest();
}