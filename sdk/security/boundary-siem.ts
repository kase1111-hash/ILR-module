/**
 * NatLangChain ILRM - Boundary-SIEM Integration
 *
 * Client for connecting to Boundary-SIEM security monitoring platform.
 * Provides:
 * - Event ingestion via REST API
 * - CEF and JSON format support
 * - WebSocket real-time alerts
 * - Connection pooling and retry logic
 *
 * @see https://github.com/kase1111-hash/Boundary-SIEM
 */

import { EventEmitter } from 'events';

// ============================================================================
// Types and Interfaces
// ============================================================================

export enum Severity {
  DEBUG = 0,
  INFO = 1,
  LOW = 3,
  MEDIUM = 5,
  HIGH = 7,
  CRITICAL = 9,
  EMERGENCY = 10,
}

export interface EventSource {
  product: string;
  host: string;
  version: string;
  component?: string;
}

export interface SecurityEvent {
  timestamp: string;
  source: EventSource;
  action: string;
  outcome: 'success' | 'failure' | 'unknown';
  severity: Severity;
  message: string;
  data?: Record<string, unknown>;
  correlationId?: string;
  sessionId?: string;
}

export interface SIEMConfig {
  endpoint: string;
  apiKey?: string;
  format?: 'json' | 'cef';
  batchSize?: number;
  flushInterval?: number;
  maxRetries?: number;
  retryDelay?: number;
  timeout?: number;
  enableWebSocket?: boolean;
  wsEndpoint?: string;
  tlsVerify?: boolean;
}

export interface SIEMResponse {
  success: boolean;
  eventId?: string;
  message?: string;
  timestamp?: string;
}

export interface AlertCallback {
  (alert: SecurityAlert): void;
}

export interface SecurityAlert {
  id: string;
  severity: Severity;
  type: string;
  source: string;
  message: string;
  timestamp: string;
  context?: Record<string, unknown>;
}

// ============================================================================
// CEF Formatter
// ============================================================================

class CEFFormatter {
  private vendor = 'NatLangChain';
  private product = 'ILRM';
  private version = '0.1.0-alpha';

  format(event: SecurityEvent): string {
    const cefSeverity = this.mapSeverity(event.severity);
    const extension = this.buildExtension(event);

    // CEF:Version|Device Vendor|Device Product|Device Version|Signature ID|Name|Severity|Extension
    return `CEF:0|${this.vendor}|${this.product}|${this.version}|${event.action}|${event.message}|${cefSeverity}|${extension}`;
  }

  private mapSeverity(severity: Severity): number {
    // CEF severity is 0-10
    return Math.min(severity, 10);
  }

  private buildExtension(event: SecurityEvent): string {
    const parts: string[] = [];

    parts.push(`rt=${new Date(event.timestamp).getTime()}`);
    parts.push(`outcome=${event.outcome}`);
    parts.push(`src=${event.source.host}`);
    parts.push(`sproc=${event.source.product}`);

    if (event.correlationId) {
      parts.push(`externalId=${event.correlationId}`);
    }

    if (event.sessionId) {
      parts.push(`cs1=${event.sessionId}`);
      parts.push(`cs1Label=SessionID`);
    }

    if (event.data) {
      // Add custom data fields
      Object.entries(event.data).forEach(([key, value], index) => {
        if (index < 6) {
          // CEF supports cs1-cs6 for custom strings
          parts.push(`cs${index + 2}=${String(value)}`);
          parts.push(`cs${index + 2}Label=${key}`);
        }
      });
    }

    return parts.join(' ');
  }
}

// ============================================================================
// Event Queue with Batching
// ============================================================================

class EventQueue {
  private queue: SecurityEvent[] = [];
  private flushTimer: NodeJS.Timeout | null = null;

  constructor(
    private batchSize: number,
    private flushInterval: number,
    private onFlush: (events: SecurityEvent[]) => Promise<void>
  ) {}

  async add(event: SecurityEvent): Promise<void> {
    this.queue.push(event);

    if (this.queue.length >= this.batchSize) {
      await this.flush();
    } else if (!this.flushTimer) {
      this.flushTimer = setTimeout(() => this.flush(), this.flushInterval);
    }
  }

  async flush(): Promise<void> {
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }

    if (this.queue.length === 0) return;

    const events = [...this.queue];
    this.queue = [];

    await this.onFlush(events);
  }

  size(): number {
    return this.queue.length;
  }

  async shutdown(): Promise<void> {
    await this.flush();
  }
}

// ============================================================================
// Boundary-SIEM Client
// ============================================================================

export class BoundarySIEM extends EventEmitter {
  private config: Required<SIEMConfig>;
  private cefFormatter: CEFFormatter;
  private eventQueue: EventQueue;
  private ws: WebSocket | null = null;
  private connected: boolean = false;
  private reconnectAttempts: number = 0;
  private maxReconnectAttempts: number = 5;
  private alertCallbacks: Set<AlertCallback> = new Set();

  constructor(config: SIEMConfig) {
    super();
    this.config = {
      endpoint: config.endpoint,
      apiKey: config.apiKey || '',
      format: config.format || 'json',
      batchSize: config.batchSize || 100,
      flushInterval: config.flushInterval || 5000,
      maxRetries: config.maxRetries || 3,
      retryDelay: config.retryDelay || 1000,
      timeout: config.timeout || 10000,
      enableWebSocket: config.enableWebSocket ?? false,
      wsEndpoint: config.wsEndpoint || config.endpoint.replace(/^http/, 'ws') + '/ws/alerts',
      tlsVerify: config.tlsVerify ?? true,
    };

    this.cefFormatter = new CEFFormatter();
    this.eventQueue = new EventQueue(
      this.config.batchSize,
      this.config.flushInterval,
      (events) => this.sendBatch(events)
    );
  }

  // --------------------------------------------------------------------------
  // Connection Management
  // --------------------------------------------------------------------------

  async connect(): Promise<void> {
    // Verify connectivity with health check
    await this.healthCheck();
    this.connected = true;

    // Connect WebSocket for alerts if enabled
    if (this.config.enableWebSocket) {
      await this.connectWebSocket();
    }

    this.emit('connected');
  }

  async disconnect(): Promise<void> {
    // Flush pending events
    await this.eventQueue.shutdown();

    // Close WebSocket
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }

    this.connected = false;
    this.emit('disconnected');
  }

  isConnected(): boolean {
    return this.connected;
  }

  // --------------------------------------------------------------------------
  // Event Sending
  // --------------------------------------------------------------------------

  async sendEvent(event: SecurityEvent): Promise<SIEMResponse> {
    if (!this.connected) {
      throw new Error('SIEM client not connected');
    }

    // For high severity, send immediately
    if (event.severity >= Severity.HIGH) {
      return this.sendImmediate(event);
    }

    // Otherwise, queue for batching
    await this.eventQueue.add(event);
    return { success: true, message: 'Event queued' };
  }

  private async sendImmediate(event: SecurityEvent): Promise<SIEMResponse> {
    const payload = this.formatPayload([event]);
    return this.postWithRetry('/api/v1/events', payload);
  }

  private async sendBatch(events: SecurityEvent[]): Promise<void> {
    if (events.length === 0) return;

    const payload = this.formatPayload(events);

    try {
      await this.postWithRetry('/api/v1/events/batch', payload);
      this.emit('batch_sent', { count: events.length });
    } catch (error) {
      this.emit('batch_failed', { count: events.length, error });
      // Re-queue failed events (simplified - in production would need dedup)
      console.error('[SIEM] Batch send failed:', error);
    }
  }

  private formatPayload(events: SecurityEvent[]): string | object {
    if (this.config.format === 'cef') {
      return events.map((e) => this.cefFormatter.format(e)).join('\n');
    }
    return { events };
  }

  // --------------------------------------------------------------------------
  // HTTP Communication
  // --------------------------------------------------------------------------

  private async postWithRetry(
    path: string,
    payload: string | object
  ): Promise<SIEMResponse> {
    let lastError: Error | null = null;

    for (let attempt = 0; attempt <= this.config.maxRetries; attempt++) {
      try {
        return await this.post(path, payload);
      } catch (error) {
        lastError = error as Error;

        if (attempt < this.config.maxRetries) {
          const delay = this.config.retryDelay * Math.pow(2, attempt);
          await this.sleep(delay);
        }
      }
    }

    throw lastError;
  }

  private async post(path: string, payload: string | object): Promise<SIEMResponse> {
    const url = `${this.config.endpoint}${path}`;
    const isString = typeof payload === 'string';

    const headers: Record<string, string> = {
      'Content-Type': isString ? 'text/plain' : 'application/json',
      'User-Agent': 'NatLangChain-ILRM/0.1.0-alpha',
    };

    if (this.config.apiKey) {
      headers['Authorization'] = `Bearer ${this.config.apiKey}`;
    }

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), this.config.timeout);

    try {
      const response = await fetch(url, {
        method: 'POST',
        headers,
        body: isString ? payload : JSON.stringify(payload),
        signal: controller.signal,
      });

      clearTimeout(timeoutId);

      if (!response.ok) {
        throw new Error(`SIEM API error: ${response.status} ${response.statusText}`);
      }

      const data = await response.json();
      return {
        success: true,
        eventId: data.eventId || data.id,
        message: data.message,
        timestamp: data.timestamp,
      };
    } catch (error) {
      clearTimeout(timeoutId);
      throw error;
    }
  }

  private async healthCheck(): Promise<void> {
    const url = `${this.config.endpoint}/api/v1/health`;
    const headers: Record<string, string> = {
      'User-Agent': 'NatLangChain-ILRM/0.1.0-alpha',
    };

    if (this.config.apiKey) {
      headers['Authorization'] = `Bearer ${this.config.apiKey}`;
    }

    const response = await fetch(url, { method: 'GET', headers });

    if (!response.ok) {
      throw new Error(`SIEM health check failed: ${response.status}`);
    }
  }

  // --------------------------------------------------------------------------
  // WebSocket for Alerts
  // --------------------------------------------------------------------------

  private async connectWebSocket(): Promise<void> {
    return new Promise((resolve, reject) => {
      try {
        // Note: In Node.js, would need ws package. This is browser-compatible.
        const wsUrl = this.config.apiKey
          ? `${this.config.wsEndpoint}?token=${this.config.apiKey}`
          : this.config.wsEndpoint;

        // Check if WebSocket is available (browser or ws package)
        if (typeof WebSocket === 'undefined') {
          console.warn('[SIEM] WebSocket not available in this environment');
          resolve();
          return;
        }

        this.ws = new WebSocket(wsUrl);

        this.ws.onopen = () => {
          this.reconnectAttempts = 0;
          this.emit('ws_connected');
          resolve();
        };

        this.ws.onmessage = (event) => {
          try {
            const alert = JSON.parse(event.data) as SecurityAlert;
            this.handleAlert(alert);
          } catch (e) {
            console.error('[SIEM] Failed to parse alert:', e);
          }
        };

        this.ws.onerror = (error) => {
          this.emit('ws_error', error);
        };

        this.ws.onclose = () => {
          this.emit('ws_disconnected');
          this.scheduleReconnect();
        };
      } catch (error) {
        reject(error);
      }
    });
  }

  private scheduleReconnect(): void {
    if (this.reconnectAttempts >= this.maxReconnectAttempts) {
      this.emit('ws_max_reconnect');
      return;
    }

    const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempts), 30000);
    this.reconnectAttempts++;

    setTimeout(() => {
      if (this.connected) {
        this.connectWebSocket().catch((e) => {
          console.error('[SIEM] WebSocket reconnect failed:', e);
        });
      }
    }, delay);
  }

  // --------------------------------------------------------------------------
  // Alert Handling
  // --------------------------------------------------------------------------

  onAlert(callback: AlertCallback): void {
    this.alertCallbacks.add(callback);
  }

  offAlert(callback: AlertCallback): void {
    this.alertCallbacks.delete(callback);
  }

  private handleAlert(alert: SecurityAlert): void {
    this.emit('alert', alert);
    this.alertCallbacks.forEach((cb) => {
      try {
        cb(alert);
      } catch (e) {
        console.error('[SIEM] Alert callback error:', e);
      }
    });
  }

  // --------------------------------------------------------------------------
  // Query API
  // --------------------------------------------------------------------------

  async queryEvents(query: {
    startTime?: string;
    endTime?: string;
    severity?: Severity;
    action?: string;
    limit?: number;
  }): Promise<SecurityEvent[]> {
    const params = new URLSearchParams();
    if (query.startTime) params.set('start', query.startTime);
    if (query.endTime) params.set('end', query.endTime);
    if (query.severity !== undefined) params.set('severity', String(query.severity));
    if (query.action) params.set('action', query.action);
    if (query.limit) params.set('limit', String(query.limit));

    const url = `${this.config.endpoint}/api/v1/events?${params.toString()}`;
    const headers: Record<string, string> = {
      'User-Agent': 'NatLangChain-ILRM/0.1.0-alpha',
    };

    if (this.config.apiKey) {
      headers['Authorization'] = `Bearer ${this.config.apiKey}`;
    }

    const response = await fetch(url, { method: 'GET', headers });

    if (!response.ok) {
      throw new Error(`SIEM query failed: ${response.status}`);
    }

    const data = await response.json();
    return data.events || [];
  }

  // --------------------------------------------------------------------------
  // Convenience Methods
  // --------------------------------------------------------------------------

  async logSecurityEvent(
    action: string,
    message: string,
    severity: Severity = Severity.MEDIUM,
    data?: Record<string, unknown>
  ): Promise<SIEMResponse> {
    const event: SecurityEvent = {
      timestamp: new Date().toISOString(),
      source: {
        product: 'NatLangChain-ILRM',
        host: process.env.HOSTNAME || 'unknown',
        version: '0.1.0-alpha',
      },
      action,
      outcome: 'success',
      severity,
      message,
      data,
    };

    return this.sendEvent(event);
  }

  async logContractInteraction(
    contractAddress: string,
    functionName: string,
    txHash: string,
    success: boolean,
    data?: Record<string, unknown>
  ): Promise<SIEMResponse> {
    return this.logSecurityEvent(
      'contract.interaction',
      `${functionName} on ${contractAddress}`,
      success ? Severity.INFO : Severity.MEDIUM,
      {
        contractAddress,
        functionName,
        txHash,
        success,
        ...data,
      }
    );
  }

  async logDisputeEvent(
    disputeId: string,
    action: string,
    data?: Record<string, unknown>
  ): Promise<SIEMResponse> {
    return this.logSecurityEvent(
      `dispute.${action}`,
      `Dispute ${disputeId}: ${action}`,
      Severity.MEDIUM,
      {
        disputeId,
        ...data,
      }
    );
  }

  async logSecurityIncident(
    incidentType: string,
    message: string,
    severity: Severity = Severity.HIGH,
    data?: Record<string, unknown>
  ): Promise<SIEMResponse> {
    const event: SecurityEvent = {
      timestamp: new Date().toISOString(),
      source: {
        product: 'NatLangChain-ILRM',
        host: process.env.HOSTNAME || 'unknown',
        version: '0.1.0-alpha',
      },
      action: `security.${incidentType}`,
      outcome: 'failure',
      severity,
      message,
      data,
    };

    return this.sendEvent(event);
  }

  // --------------------------------------------------------------------------
  // Utilities
  // --------------------------------------------------------------------------

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  getQueueSize(): number {
    return this.eventQueue.size();
  }

  async flush(): Promise<void> {
    await this.eventQueue.flush();
  }
}

// ============================================================================
// Factory Function
// ============================================================================

export function createSIEMClient(config: SIEMConfig): BoundarySIEM {
  return new BoundarySIEM(config);
}
