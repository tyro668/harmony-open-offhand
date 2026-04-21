import hiAppEvent from '@ohos.hiviewdfx.hiAppEvent';

interface TelemetryAppEventParams {
  payload: string;
}

const DOMAIN = 'offhand_ime';

export class ImeTelemetry {
  static trackBehavior(name: string, payload: string = ''): void {
    void ImeTelemetry.write(name, hiAppEvent.EventType.BEHAVIOR, payload);
  }

  static trackStatistic(name: string, payload: string = ''): void {
    void ImeTelemetry.write(name, hiAppEvent.EventType.STATISTIC, payload);
  }

  private static async write(name: string, eventType: number, payload: string): Promise<void> {
    let params: TelemetryAppEventParams = {
      payload: payload
    };
    try {
      await hiAppEvent.write({
        domain: DOMAIN,
        name: name,
        eventType: eventType,
        params: params
      });
    } catch (_) {
    }
  }
}
