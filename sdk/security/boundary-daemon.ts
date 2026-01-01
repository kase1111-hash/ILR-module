/**
 * NatLangChain ILRM - Boundary-Daemon Integration
 *
 * Client for connecting to boundary-daemon security policy enforcement.
 * Provides:
 * - Unix socket communication
 * - Policy evaluation and enforcement
 * - Connection protection (iptables/nftables integration)
 * - Audit logging with CEF/LEEF formats
 *
 * @see https://github.com/kase1111-hash/boundary-daemon-
 */

import { EventEmitter } from 'events';
import * as net from 'net';
import * as fs from 'fs';

// ============================================================================
// Types and Interfaces
// ============================================================================

export enum PolicyDecision {
  ALLOW = 'ALLOW',
  DENY = 'DENY',
  MONITOR = 'MONITOR',
  RATE_LIMIT = 'RATE_LIMIT',
}

export enum RuleAction {
  ACCEPT = 'ACCEPT',
  DROP = 'DROP',
  REJECT = 'REJECT',
  LOG = 'LOG',
}

export interface PolicyContext {
  action: string;
  context: Record<string, unknown>;
  severity?: number;
  source?: string;
  destination?: string;
  protocol?: string;
  port?: number;
}

export interface PolicyResult {
  decision: PolicyDecision;
  ruleId?: string;
  reason?: string;
  actions?: string[];
  metadata?: Record<string, unknown>;
}

export interface ConnectionRule {
  id: string;
  priority: number;
  source?: string;
  destination?: string;
  protocol?: 'tcp' | 'udp' | 'any';
  port?: number | string;
  action: RuleAction;
  rateLimit?: {
    requests: number;
    window: number; // seconds
  };
  enabled: boolean;
}

export interface DaemonConfig {
  socketPath?: string;
  host?: string;
  port?: number;
  timeout?: number;
  reconnectInterval?: number;
  maxReconnectAttempts?: number;
  enableAudit?: boolean;
  auditFormat?: 'cef' | 'leef' | 'json';
}

export interface AuditEvent {
  timestamp: string;
  eventType: string;
  decision: PolicyDecision;
  context: PolicyContext;
  ruleId?: string;
  source?: string;
}

export interface DaemonStatus {
  connected: boolean;
  version: string;
  uptime: number;
  rulesCount: number;
  policiesCount: number;
  lastPolicyUpdate: string;
}

// ============================================================================
// Message Protocol
// ============================================================================

interface DaemonMessage {
  id: string;
  type: 'request' | 'response' | 'event';
  command: string;
  payload: unknown;
  timestamp: string;
}

interface DaemonRequest {
  id: string;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
}

// ============================================================================
// CEF/LEEF Formatters
// ============================================================================

class AuditFormatter {
  private format: 'cef' | 'leef' | 'json';

  constructor(format: 'cef' | 'leef' | 'json' = 'json') {
    this.format = format;
  }

  formatEvent(event: AuditEvent): string {
    switch (this.format) {
      case 'cef':
        return this.toCEF(event);
      case 'leef':
        return this.toLEEF(event);
      default:
        return JSON.stringify(event);
    }
  }

  private toCEF(event: AuditEvent): string {
    const severity = this.getSeverity(event.decision);
    const extension = [
      `rt=${new Date(event.timestamp).getTime()}`,
      `act=${event.context.action}`,
      `outcome=${event.decision}`,
      event.ruleId ? `cs1=${event.ruleId}` : '',
      event.ruleId ? `cs1Label=RuleID` : '',
      event.source ? `src=${event.source}` : '',
    ]
      .filter(Boolean)
      .join(' ');

    return `CEF:0|NatLangChain|BoundaryDaemon|1.0|${event.eventType}|Policy Decision|${severity}|${extension}`;
  }

  private toLEEF(event: AuditEvent): string {
    const attrs = [
      `devTime=${event.timestamp}`,
      `cat=${event.eventType}`,
      `action=${event.context.action}`,
      `policy=${event.decision}`,
      event.ruleId ? `ruleId=${event.ruleId}` : '',
      event.source ? `src=${event.source}` : '',
    ]
      .filter(Boolean)
      .join('\t');

    return `LEEF:2.0|NatLangChain|BoundaryDaemon|1.0|${event.eventType}|${attrs}`;
  }

  private getSeverity(decision: PolicyDecision): number {
    switch (decision) {
      case PolicyDecision.DENY:
        return 8;
      case PolicyDecision.RATE_LIMIT:
        return 5;
      case PolicyDecision.MONITOR:
        return 3;
      default:
        return 1;
    }
  }
}

// ============================================================================
// Boundary Daemon Client
// ============================================================================

export class BoundaryDaemon extends EventEmitter {
  private config: Required<DaemonConfig>;
  private socket: net.Socket | null = null;
  private connected: boolean = false;
  private reconnecting: boolean = false;
  private reconnectAttempts: number = 0;
  private pendingRequests: Map<string, DaemonRequest> = new Map();
  private messageBuffer: string = '';
  private auditFormatter: AuditFormatter;
  private requestCounter: number = 0;

  constructor(config: DaemonConfig = {}) {
    super();
    this.config = {
      socketPath: config.socketPath || '/var/run/boundary-daemon/daemon.sock',
      host: config.host || '',
      port: config.port || 0,
      timeout: config.timeout || 5000,
      reconnectInterval: config.reconnectInterval || 5000,
      maxReconnectAttempts: config.maxReconnectAttempts || 10,
      enableAudit: config.enableAudit ?? true,
      auditFormat: config.auditFormat || 'json',
    };

    this.auditFormatter = new AuditFormatter(this.config.auditFormat);
  }

  // --------------------------------------------------------------------------
  // Connection Management
  // --------------------------------------------------------------------------

  async connect(): Promise<void> {
    if (this.connected) {
      return;
    }

    return new Promise((resolve, reject) => {
      const useUnixSocket = this.config.socketPath && !this.config.host;

      if (useUnixSocket) {
        // Check if socket exists
        if (!fs.existsSync(this.config.socketPath)) {
          reject(new Error(`Daemon socket not found: ${this.config.socketPath}`));
          return;
        }
        this.socket = net.createConnection({ path: this.config.socketPath });
      } else {
        this.socket = net.createConnection({
          host: this.config.host,
          port: this.config.port,
        });
      }

      this.socket.setEncoding('utf8');

      this.socket.on('connect', () => {
        this.connected = true;
        this.reconnecting = false;
        this.reconnectAttempts = 0;
        this.emit('connected');
        resolve();
      });

      this.socket.on('data', (data) => {
        this.handleData(data);
      });

      this.socket.on('error', (error) => {
        this.emit('error', error);
        if (!this.connected) {
          reject(error);
        }
      });

      this.socket.on('close', () => {
        this.connected = false;
        this.emit('disconnected');
        this.scheduleReconnect();
      });

      // Connection timeout
      setTimeout(() => {
        if (!this.connected) {
          this.socket?.destroy();
          reject(new Error('Connection timeout'));
        }
      }, this.config.timeout);
    });
  }

  async disconnect(): Promise<void> {
    this.reconnecting = false; // Prevent auto-reconnect

    if (this.socket) {
      this.socket.end();
      this.socket.destroy();
      this.socket = null;
    }

    this.connected = false;

    // Reject all pending requests
    for (const [id, request] of this.pendingRequests) {
      clearTimeout(request.timeout);
      request.reject(new Error('Connection closed'));
      this.pendingRequests.delete(id);
    }
  }

  isConnected(): boolean {
    return this.connected;
  }

  private scheduleReconnect(): void {
    if (this.reconnecting) return;
    if (this.reconnectAttempts >= this.config.maxReconnectAttempts) {
      this.emit('max_reconnect_attempts');
      return;
    }

    this.reconnecting = true;
    this.reconnectAttempts++;

    const delay = Math.min(
      this.config.reconnectInterval * Math.pow(1.5, this.reconnectAttempts - 1),
      60000
    );

    setTimeout(() => {
      this.reconnecting = false;
      this.connect().catch((e) => {
        console.error('[Daemon] Reconnect failed:', e.message);
      });
    }, delay);
  }

  // --------------------------------------------------------------------------
  // Message Protocol
  // --------------------------------------------------------------------------

  private handleData(data: string): void {
    this.messageBuffer += data;

    // Messages are newline-delimited JSON
    const lines = this.messageBuffer.split('\n');
    this.messageBuffer = lines.pop() || '';

    for (const line of lines) {
      if (!line.trim()) continue;

      try {
        const message: DaemonMessage = JSON.parse(line);
        this.handleMessage(message);
      } catch (e) {
        console.error('[Daemon] Failed to parse message:', e);
      }
    }
  }

  private handleMessage(message: DaemonMessage): void {
    if (message.type === 'response') {
      const request = this.pendingRequests.get(message.id);
      if (request) {
        clearTimeout(request.timeout);
        this.pendingRequests.delete(message.id);
        request.resolve(message.payload);
      }
    } else if (message.type === 'event') {
      this.emit('daemon_event', message);
    }
  }

  private async sendRequest(command: string, payload: unknown): Promise<unknown> {
    if (!this.connected || !this.socket) {
      throw new Error('Not connected to daemon');
    }

    const id = `req_${++this.requestCounter}_${Date.now()}`;
    const message: DaemonMessage = {
      id,
      type: 'request',
      command,
      payload,
      timestamp: new Date().toISOString(),
    };

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingRequests.delete(id);
        reject(new Error(`Request timeout: ${command}`));
      }, this.config.timeout);

      this.pendingRequests.set(id, { id, resolve, reject, timeout });

      try {
        this.socket!.write(JSON.stringify(message) + '\n');
      } catch (e) {
        clearTimeout(timeout);
        this.pendingRequests.delete(id);
        reject(e);
      }
    });
  }

  // --------------------------------------------------------------------------
  // Policy Evaluation
  // --------------------------------------------------------------------------

  async checkPolicy(context: PolicyContext): Promise<PolicyDecision> {
    const result = await this.evaluatePolicy(context);

    // Audit logging
    if (this.config.enableAudit) {
      await this.audit({
        timestamp: new Date().toISOString(),
        eventType: 'policy.check',
        decision: result.decision,
        context,
        ruleId: result.ruleId,
      });
    }

    return result.decision;
  }

  async evaluatePolicy(context: PolicyContext): Promise<PolicyResult> {
    try {
      const response = (await this.sendRequest('policy.evaluate', context)) as PolicyResult;
      return response;
    } catch (error) {
      // Fail-open or fail-closed depending on security posture
      // Default to MONITOR to log but not block
      console.error('[Daemon] Policy evaluation failed:', error);
      return {
        decision: PolicyDecision.MONITOR,
        reason: 'Daemon unavailable - defaulting to monitor',
      };
    }
  }

  async batchCheckPolicy(contexts: PolicyContext[]): Promise<PolicyResult[]> {
    try {
      const response = (await this.sendRequest(
        'policy.evaluate_batch',
        { contexts }
      )) as { results: PolicyResult[] };
      return response.results;
    } catch (error) {
      console.error('[Daemon] Batch policy check failed:', error);
      return contexts.map(() => ({
        decision: PolicyDecision.MONITOR,
        reason: 'Daemon unavailable',
      }));
    }
  }

  // --------------------------------------------------------------------------
  // Connection Protection
  // --------------------------------------------------------------------------

  async protectConnection(
    source: string,
    destination: string,
    protocol: 'tcp' | 'udp' = 'tcp',
    port?: number
  ): Promise<boolean> {
    const context: PolicyContext = {
      action: 'connection.establish',
      context: {},
      source,
      destination,
      protocol,
      port,
    };

    const decision = await this.checkPolicy(context);
    return decision === PolicyDecision.ALLOW;
  }

  async addConnectionRule(rule: Omit<ConnectionRule, 'id'>): Promise<string> {
    const response = (await this.sendRequest('rules.add', rule)) as { id: string };
    return response.id;
  }

  async removeConnectionRule(ruleId: string): Promise<boolean> {
    const response = (await this.sendRequest('rules.remove', { id: ruleId })) as {
      success: boolean;
    };
    return response.success;
  }

  async listConnectionRules(): Promise<ConnectionRule[]> {
    const response = (await this.sendRequest('rules.list', {})) as {
      rules: ConnectionRule[];
    };
    return response.rules;
  }

  async updateConnectionRule(
    ruleId: string,
    updates: Partial<ConnectionRule>
  ): Promise<boolean> {
    const response = (await this.sendRequest('rules.update', {
      id: ruleId,
      ...updates,
    })) as { success: boolean };
    return response.success;
  }

  // --------------------------------------------------------------------------
  // Rate Limiting
  // --------------------------------------------------------------------------

  async checkRateLimit(
    identifier: string,
    action: string,
    limit?: { requests: number; window: number }
  ): Promise<{ allowed: boolean; remaining: number; resetAt: number }> {
    const response = (await this.sendRequest('ratelimit.check', {
      identifier,
      action,
      limit,
    })) as { allowed: boolean; remaining: number; resetAt: number };
    return response;
  }

  async resetRateLimit(identifier: string, action?: string): Promise<void> {
    await this.sendRequest('ratelimit.reset', { identifier, action });
  }

  // --------------------------------------------------------------------------
  // Firewall Integration
  // --------------------------------------------------------------------------

  async blockIP(
    ip: string,
    reason: string,
    duration?: number
  ): Promise<boolean> {
    const response = (await this.sendRequest('firewall.block', {
      ip,
      reason,
      duration,
    })) as { success: boolean };

    await this.audit({
      timestamp: new Date().toISOString(),
      eventType: 'firewall.block',
      decision: PolicyDecision.DENY,
      context: {
        action: 'firewall.block',
        context: { ip, reason, duration },
        source: ip,
      },
    });

    return response.success;
  }

  async unblockIP(ip: string): Promise<boolean> {
    const response = (await this.sendRequest('firewall.unblock', { ip })) as {
      success: boolean;
    };
    return response.success;
  }

  async listBlockedIPs(): Promise<
    Array<{ ip: string; reason: string; blockedAt: string; expiresAt?: string }>
  > {
    const response = (await this.sendRequest('firewall.list', {})) as {
      blocked: Array<{
        ip: string;
        reason: string;
        blockedAt: string;
        expiresAt?: string;
      }>;
    };
    return response.blocked;
  }

  // --------------------------------------------------------------------------
  // Audit Logging
  // --------------------------------------------------------------------------

  async audit(event: AuditEvent): Promise<void> {
    if (!this.config.enableAudit) return;

    const formatted = this.auditFormatter.formatEvent(event);

    try {
      await this.sendRequest('audit.log', { event: formatted, raw: event });
    } catch (error) {
      // Fallback to local logging
      console.log('[Daemon Audit]', formatted);
    }

    this.emit('audit', event);
  }

  // --------------------------------------------------------------------------
  // Status and Health
  // --------------------------------------------------------------------------

  async getStatus(): Promise<DaemonStatus> {
    const response = (await this.sendRequest('status', {})) as DaemonStatus;
    return response;
  }

  async healthCheck(): Promise<boolean> {
    try {
      await this.sendRequest('health', {});
      return true;
    } catch {
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // ILRM-Specific Methods
  // --------------------------------------------------------------------------

  async checkDisputeAction(
    disputeId: string,
    action: string,
    actor: string,
    data?: Record<string, unknown>
  ): Promise<PolicyDecision> {
    return this.checkPolicy({
      action: `dispute.${action}`,
      context: {
        disputeId,
        actor,
        ...data,
      },
      severity: action === 'fraudProof' ? 9 : 5,
    });
  }

  async checkBridgeOperation(
    operation: string,
    stateRoot: string,
    submitter: string
  ): Promise<PolicyDecision> {
    return this.checkPolicy({
      action: `bridge.${operation}`,
      context: {
        stateRoot,
        submitter,
      },
      severity: 7,
    });
  }

  async checkTreasuryWithdrawal(
    amount: bigint,
    recipient: string,
    token: string
  ): Promise<PolicyDecision> {
    return this.checkPolicy({
      action: 'treasury.withdrawal',
      context: {
        amount: amount.toString(),
        recipient,
        token,
      },
      severity: amount > BigInt(1e18) ? 9 : 7,
    });
  }

  async protectRPCConnection(
    rpcUrl: string,
    chainId: number
  ): Promise<boolean> {
    const url = new URL(rpcUrl);
    return this.protectConnection(
      process.env.HOSTNAME || 'localhost',
      url.hostname,
      'tcp',
      parseInt(url.port) || (url.protocol === 'https:' ? 443 : 80)
    );
  }
}

// ============================================================================
// Factory Function
// ============================================================================

export function createDaemonClient(config?: DaemonConfig): BoundaryDaemon {
  return new BoundaryDaemon(config);
}

// ============================================================================
// Mock Client for Testing
// ============================================================================

export class MockBoundaryDaemon extends BoundaryDaemon {
  private mockDecisions: Map<string, PolicyDecision> = new Map();
  private mockRules: ConnectionRule[] = [];

  constructor() {
    super({ socketPath: '' });
    (this as { connected: boolean }).connected = true;
  }

  async connect(): Promise<void> {
    (this as { connected: boolean }).connected = true;
    this.emit('connected');
  }

  async disconnect(): Promise<void> {
    (this as { connected: boolean }).connected = false;
    this.emit('disconnected');
  }

  setMockDecision(action: string, decision: PolicyDecision): void {
    this.mockDecisions.set(action, decision);
  }

  async checkPolicy(context: PolicyContext): Promise<PolicyDecision> {
    return this.mockDecisions.get(context.action) || PolicyDecision.ALLOW;
  }

  async evaluatePolicy(context: PolicyContext): Promise<PolicyResult> {
    const decision = this.mockDecisions.get(context.action) || PolicyDecision.ALLOW;
    return { decision, reason: 'Mock decision' };
  }

  async addConnectionRule(rule: Omit<ConnectionRule, 'id'>): Promise<string> {
    const id = `mock_rule_${this.mockRules.length}`;
    this.mockRules.push({ ...rule, id } as ConnectionRule);
    return id;
  }

  async listConnectionRules(): Promise<ConnectionRule[]> {
    return this.mockRules;
  }
}
