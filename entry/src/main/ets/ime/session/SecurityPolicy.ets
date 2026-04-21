import { inputMethodEngine } from '@kit.IMEKit';
import { SessionCapabilitySnapshot } from '../common/ImeTypes';

export class SecurityPolicy {
  static resolve(pattern: number, securityMode: number, voiceRequested: boolean, polishRequested: boolean,
    personalizationEnabled: boolean): SessionCapabilitySnapshot {
    if (SecurityPolicy.isSensitivePattern(pattern)) {
      return {
        voiceEnabled: false,
        polishEnabled: false,
        personalizedLearning: false,
        restrictedReason: 'Sensitive field',
        isSensitiveField: true
      };
    }

    if (SecurityPolicy.isEmailOrUriPattern(pattern)) {
      return {
        voiceEnabled: voiceRequested,
        polishEnabled: false,
        personalizedLearning: personalizationEnabled,
        restrictedReason: 'Email or URL field',
        isSensitiveField: false
      };
    }

    if (securityMode === inputMethodEngine.SecurityMode.FULL && SecurityPolicy.isUnknownPattern(pattern)) {
      return {
        voiceEnabled: false,
        polishEnabled: false,
        personalizedLearning: false,
        restrictedReason: 'Security mode full with unknown pattern',
        isSensitiveField: true
      };
    }

    return {
      voiceEnabled: voiceRequested,
      polishEnabled: polishRequested,
      personalizedLearning: personalizationEnabled,
      restrictedReason: securityMode === inputMethodEngine.SecurityMode.FULL ?
        'Pattern-based policy under full security mode' : 'Standard text field',
      isSensitiveField: false
    };
  }

  static isSensitivePattern(pattern: number): boolean {
    return pattern === inputMethodEngine.PATTERN_PASSWORD ||
      pattern === inputMethodEngine.PATTERN_PASSWORD_NUMBER ||
      pattern === inputMethodEngine.PATTERN_PASSWORD_SCREEN_LOCK ||
      pattern === inputMethodEngine.PATTERN_NEW_PASSWORD ||
      pattern === inputMethodEngine.PATTERN_ONE_TIME_CODE;
  }

  static isEmailOrUriPattern(pattern: number): boolean {
    return pattern === inputMethodEngine.PATTERN_EMAIL ||
      pattern === inputMethodEngine.PATTERN_URI;
  }

  static isUnknownPattern(pattern: number): boolean {
    return pattern < 0 || pattern === inputMethodEngine.PATTERN_NULL;
  }

  static describePattern(pattern: number): string {
    if (SecurityPolicy.isUnknownPattern(pattern)) {
      return `unknown-${pattern}`;
    }
    if (pattern === inputMethodEngine.PATTERN_TEXT) {
      return 'text';
    }
    if (pattern === inputMethodEngine.PATTERN_NUMBER || pattern === inputMethodEngine.PATTERN_NUMBER_DECIMAL) {
      return 'number';
    }
    if (pattern === inputMethodEngine.PATTERN_PHONE) {
      return 'phone';
    }
    if (pattern === inputMethodEngine.PATTERN_EMAIL) {
      return 'email';
    }
    if (pattern === inputMethodEngine.PATTERN_URI) {
      return 'url';
    }
    if (SecurityPolicy.isSensitivePattern(pattern)) {
      return 'sensitive';
    }
    return `pattern-${pattern}`;
  }
}
