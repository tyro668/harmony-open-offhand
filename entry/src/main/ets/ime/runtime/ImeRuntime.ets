import { SessionManager } from '../session/SessionManager';

class ImeRuntime {
  private sessionManager?: SessionManager;

  setSessionManager(sessionManager: SessionManager): void {
    this.sessionManager = sessionManager;
  }

  getSessionManager(): SessionManager | undefined {
    return this.sessionManager;
  }
}

export const imeRuntime: ImeRuntime = new ImeRuntime();
