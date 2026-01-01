/**
 * NatLangChain ILRM - Security Configuration
 *
 * Centralized configuration for security module integrations.
 */

import { SIEMConfig, BoundarySIEM, createSIEMClient } from './boundary-siem';
import {
  DaemonConfig,
  BoundaryDaemon,
  createDaemonClient,
  MockBoundaryDaemon,
} from './boundary-daemon';
import {
  ErrorHandler,
  ErrorHandlerConfig,
  initializeErrorHandler,
  ErrorSeverity,
} from './errors';

// ============================================================================
// Environment Configuration
// ============================================================================

export interface SecurityConfig {
  // SIEM Configuration
  siem?: {
    enabled: boolean;
    endpoint: string;
    apiKey?: string;
    format?: 'json' | 'cef';
    batchSize?: number;
    flushInterval?: number;
    enableWebSocket?: boolean;
  };

  // Daemon Configuration
  daemon?: {
    enabled: boolean;
    socketPath?: string;
    host?: string;
    port?: number;
    enableAudit?: boolean;
    auditFormat?: 'cef' | 'leef' | 'json';
  };

  // Error Handler Configuration
  errorHandler?: {
    minReportSeverity?: ErrorSeverity;
  };

  // General Settings
  environment?: 'development' | 'staging' | 'production';
  debugMode?: boolean;
}

// ============================================================================
// Default Configurations
// ============================================================================

const DEFAULT_DEV_CONFIG: SecurityConfig = {
  siem: {
    enabled: false,
    endpoint: 'http://localhost:8080',
    format: 'json',
    batchSize: 10,
    flushInterval: 1000,
    enableWebSocket: false,
  },
  daemon: {
    enabled: false,
    socketPath: '/var/run/boundary-daemon/daemon.sock',
    enableAudit: true,
    auditFormat: 'json',
  },
  errorHandler: {
    minReportSeverity: ErrorSeverity.DEBUG,
  },
  environment: 'development',
  debugMode: true,
};

const DEFAULT_PROD_CONFIG: SecurityConfig = {
  siem: {
    enabled: true,
    endpoint: process.env.SIEM_ENDPOINT || 'https://siem.boundary.io',
    apiKey: process.env.SIEM_API_KEY,
    format: 'cef',
    batchSize: 100,
    flushInterval: 5000,
    enableWebSocket: true,
  },
  daemon: {
    enabled: true,
    socketPath: process.env.DAEMON_SOCKET || '/var/run/boundary-daemon/daemon.sock',
    enableAudit: true,
    auditFormat: 'cef',
  },
  errorHandler: {
    minReportSeverity: ErrorSeverity.MEDIUM,
  },
  environment: 'production',
  debugMode: false,
};

// ============================================================================
// Configuration Loader
// ============================================================================

export function loadConfigFromEnv(): SecurityConfig {
  const env = process.env.NODE_ENV || 'development';
  const baseConfig = env === 'production' ? DEFAULT_PROD_CONFIG : DEFAULT_DEV_CONFIG;

  return {
    ...baseConfig,
    siem: {
      ...baseConfig.siem!,
      enabled: process.env.SIEM_ENABLED === 'true',
      endpoint: process.env.SIEM_ENDPOINT || baseConfig.siem!.endpoint,
      apiKey: process.env.SIEM_API_KEY || baseConfig.siem!.apiKey,
      format: (process.env.SIEM_FORMAT as 'json' | 'cef') || baseConfig.siem!.format,
      enableWebSocket: process.env.SIEM_WEBSOCKET === 'true',
    },
    daemon: {
      ...baseConfig.daemon!,
      enabled: process.env.DAEMON_ENABLED === 'true',
      socketPath: process.env.DAEMON_SOCKET || baseConfig.daemon!.socketPath,
      host: process.env.DAEMON_HOST,
      port: process.env.DAEMON_PORT ? parseInt(process.env.DAEMON_PORT) : undefined,
    },
    environment: env as 'development' | 'staging' | 'production',
    debugMode: process.env.DEBUG === 'true',
  };
}

// ============================================================================
// Security Manager
// ============================================================================

export class SecurityManager {
  private siem: BoundarySIEM | null = null;
  private daemon: BoundaryDaemon | null = null;
  private errorHandler: ErrorHandler | null = null;
  private config: SecurityConfig;
  private initialized: boolean = false;

  constructor(config?: SecurityConfig) {
    this.config = config || loadConfigFromEnv();
  }

  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }

    // Initialize SIEM client
    if (this.config.siem?.enabled) {
      this.siem = createSIEMClient({
        endpoint: this.config.siem.endpoint,
        apiKey: this.config.siem.apiKey,
        format: this.config.siem.format,
        batchSize: this.config.siem.batchSize,
        flushInterval: this.config.siem.flushInterval,
        enableWebSocket: this.config.siem.enableWebSocket,
      });

      try {
        await this.siem.connect();
        console.log('[Security] SIEM client connected');
      } catch (error) {
        console.error('[Security] Failed to connect to SIEM:', error);
        if (this.config.environment === 'production') {
          throw error;
        }
      }
    }

    // Initialize Daemon client
    if (this.config.daemon?.enabled) {
      this.daemon = createDaemonClient({
        socketPath: this.config.daemon.socketPath,
        host: this.config.daemon.host,
        port: this.config.daemon.port,
        enableAudit: this.config.daemon.enableAudit,
        auditFormat: this.config.daemon.auditFormat,
      });

      try {
        await this.daemon.connect();
        console.log('[Security] Daemon client connected');
      } catch (error) {
        console.error('[Security] Failed to connect to daemon:', error);
        if (this.config.environment === 'production') {
          throw error;
        }
      }
    }

    // Initialize Error Handler with integrations
    this.errorHandler = initializeErrorHandler({
      siem: this.siem || undefined,
      daemon: this.daemon || undefined,
      enableSIEMReporting: this.config.siem?.enabled || false,
      enableDaemonProtection: this.config.daemon?.enabled || false,
      minReportSeverity: this.config.errorHandler?.minReportSeverity,
    });

    this.initialized = true;
    console.log('[Security] Security manager initialized');
  }

  async shutdown(): Promise<void> {
    if (this.siem) {
      await this.siem.disconnect();
      this.siem = null;
    }

    if (this.daemon) {
      await this.daemon.disconnect();
      this.daemon = null;
    }

    this.initialized = false;
    console.log('[Security] Security manager shutdown');
  }

  getSIEM(): BoundarySIEM | null {
    return this.siem;
  }

  getDaemon(): BoundaryDaemon | null {
    return this.daemon;
  }

  getErrorHandler(): ErrorHandler | null {
    return this.errorHandler;
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  getConfig(): SecurityConfig {
    return this.config;
  }
}

// ============================================================================
// Global Instance
// ============================================================================

let globalSecurityManager: SecurityManager | null = null;

export function getSecurityManager(): SecurityManager {
  if (!globalSecurityManager) {
    globalSecurityManager = new SecurityManager();
  }
  return globalSecurityManager;
}

export async function initializeSecurity(config?: SecurityConfig): Promise<SecurityManager> {
  globalSecurityManager = new SecurityManager(config);
  await globalSecurityManager.initialize();
  return globalSecurityManager;
}

export async function shutdownSecurity(): Promise<void> {
  if (globalSecurityManager) {
    await globalSecurityManager.shutdown();
    globalSecurityManager = null;
  }
}

// ============================================================================
// Test Utilities
// ============================================================================

export function createTestSecurityManager(): SecurityManager {
  const manager = new SecurityManager({
    siem: { enabled: false, endpoint: '' },
    daemon: { enabled: false },
    environment: 'development',
    debugMode: true,
  });

  // Use mock daemon for testing
  (manager as unknown as { daemon: BoundaryDaemon }).daemon = new MockBoundaryDaemon();

  return manager;
}
