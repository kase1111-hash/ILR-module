/**
 * NatLangChain ILRM - Error Handling Infrastructure
 *
 * Provides comprehensive error handling with:
 * - Typed error classes for different failure modes
 * - Error severity classification
 * - Automatic SIEM reporting integration
 * - Retry logic with exponential backoff
 * - Circuit breaker pattern for external services
 */

import { BoundarySIEM, SecurityEvent, Severity } from './boundary-siem';
import { BoundaryDaemon, PolicyDecision } from './boundary-daemon';

// ============================================================================
// Error Severity Levels
// ============================================================================

export enum ErrorSeverity {
  DEBUG = 0,
  INFO = 1,
  LOW = 3,
  MEDIUM = 5,
  HIGH = 7,
  CRITICAL = 9,
  EMERGENCY = 10,
}

// ============================================================================
// Error Categories
// ============================================================================

export enum ErrorCategory {
  // Contract Errors
  CONTRACT_REVERT = 'contract.revert',
  CONTRACT_OUT_OF_GAS = 'contract.out_of_gas',
  CONTRACT_INVALID_STATE = 'contract.invalid_state',

  // Network Errors
  NETWORK_TIMEOUT = 'network.timeout',
  NETWORK_CONNECTION_REFUSED = 'network.connection_refused',
  NETWORK_RPC_ERROR = 'network.rpc_error',

  // Security Errors
  SECURITY_UNAUTHORIZED = 'security.unauthorized',
  SECURITY_INVALID_SIGNATURE = 'security.invalid_signature',
  SECURITY_REPLAY_ATTACK = 'security.replay_attack',
  SECURITY_MEV_DETECTED = 'security.mev_detected',
  SECURITY_FRAUD_ATTEMPT = 'security.fraud_attempt',

  // Validation Errors
  VALIDATION_INVALID_INPUT = 'validation.invalid_input',
  VALIDATION_SCHEMA_MISMATCH = 'validation.schema_mismatch',
  VALIDATION_BOUNDS_EXCEEDED = 'validation.bounds_exceeded',

  // Oracle Errors
  ORACLE_STALE_DATA = 'oracle.stale_data',
  ORACLE_MANIPULATION = 'oracle.manipulation',
  ORACLE_UNAVAILABLE = 'oracle.unavailable',

  // Bridge Errors
  BRIDGE_STATE_MISMATCH = 'bridge.state_mismatch',
  BRIDGE_PROOF_INVALID = 'bridge.proof_invalid',
  BRIDGE_SEQUENCER_ERROR = 'bridge.sequencer_error',

  // System Errors
  SYSTEM_INTERNAL = 'system.internal',
  SYSTEM_CONFIGURATION = 'system.configuration',
  SYSTEM_RESOURCE_EXHAUSTED = 'system.resource_exhausted',
}

// ============================================================================
// Base Error Class
// ============================================================================

export interface ErrorContext {
  disputeId?: string;
  transactionHash?: string;
  blockNumber?: number;
  contractAddress?: string;
  functionName?: string;
  caller?: string;
  timestamp?: Date;
  chainId?: number;
  additionalData?: Record<string, unknown>;
}

export class ILRMError extends Error {
  public readonly category: ErrorCategory;
  public readonly severity: ErrorSeverity;
  public readonly code: string;
  public readonly context: ErrorContext;
  public readonly originalError?: Error;
  public readonly timestamp: Date;
  public readonly retryable: boolean;

  constructor(
    message: string,
    category: ErrorCategory,
    severity: ErrorSeverity,
    context: ErrorContext = {},
    originalError?: Error,
    retryable: boolean = false
  ) {
    super(message);
    this.name = 'ILRMError';
    this.category = category;
    this.severity = severity;
    this.code = `ILRM_${category.toUpperCase().replace(/\./g, '_')}`;
    this.context = {
      ...context,
      timestamp: context.timestamp || new Date(),
    };
    this.originalError = originalError;
    this.timestamp = new Date();
    this.retryable = retryable;

    // Capture stack trace
    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, ILRMError);
    }
  }

  toJSON(): Record<string, unknown> {
    return {
      name: this.name,
      message: this.message,
      code: this.code,
      category: this.category,
      severity: this.severity,
      context: this.context,
      timestamp: this.timestamp.toISOString(),
      retryable: this.retryable,
      stack: this.stack,
      originalError: this.originalError?.message,
    };
  }

  toSecurityEvent(): SecurityEvent {
    return {
      timestamp: this.timestamp.toISOString(),
      source: {
        product: 'NatLangChain-ILRM',
        host: process.env.HOSTNAME || 'unknown',
        version: '1.5',
      },
      action: this.category,
      outcome: 'failure',
      severity: this.severity,
      message: this.message,
      data: {
        code: this.code,
        context: this.context,
        retryable: this.retryable,
      },
    };
  }
}

// ============================================================================
// Specialized Error Classes
// ============================================================================

export class ContractError extends ILRMError {
  constructor(
    message: string,
    context: ErrorContext = {},
    originalError?: Error
  ) {
    super(
      message,
      ErrorCategory.CONTRACT_REVERT,
      ErrorSeverity.MEDIUM,
      context,
      originalError,
      false
    );
    this.name = 'ContractError';
  }
}

export class NetworkError extends ILRMError {
  constructor(
    message: string,
    context: ErrorContext = {},
    originalError?: Error
  ) {
    super(
      message,
      ErrorCategory.NETWORK_RPC_ERROR,
      ErrorSeverity.MEDIUM,
      context,
      originalError,
      true // Network errors are typically retryable
    );
    this.name = 'NetworkError';
  }
}

export class SecurityError extends ILRMError {
  constructor(
    message: string,
    category: ErrorCategory = ErrorCategory.SECURITY_UNAUTHORIZED,
    context: ErrorContext = {},
    originalError?: Error
  ) {
    super(
      message,
      category,
      ErrorSeverity.CRITICAL, // Security errors are always critical
      context,
      originalError,
      false
    );
    this.name = 'SecurityError';
  }
}

export class ValidationError extends ILRMError {
  constructor(
    message: string,
    context: ErrorContext = {},
    originalError?: Error
  ) {
    super(
      message,
      ErrorCategory.VALIDATION_INVALID_INPUT,
      ErrorSeverity.LOW,
      context,
      originalError,
      false
    );
    this.name = 'ValidationError';
  }
}

export class OracleError extends ILRMError {
  constructor(
    message: string,
    category: ErrorCategory = ErrorCategory.ORACLE_UNAVAILABLE,
    context: ErrorContext = {},
    originalError?: Error
  ) {
    super(
      message,
      category,
      ErrorSeverity.HIGH,
      context,
      originalError,
      true
    );
    this.name = 'OracleError';
  }
}

export class BridgeError extends ILRMError {
  constructor(
    message: string,
    category: ErrorCategory = ErrorCategory.BRIDGE_STATE_MISMATCH,
    context: ErrorContext = {},
    originalError?: Error
  ) {
    super(
      message,
      category,
      ErrorSeverity.HIGH,
      context,
      originalError,
      false
    );
    this.name = 'BridgeError';
  }
}

// ============================================================================
// Error Handler with SIEM Integration
// ============================================================================

export interface ErrorHandlerConfig {
  siem?: BoundarySIEM;
  daemon?: BoundaryDaemon;
  enableSIEMReporting?: boolean;
  enableDaemonProtection?: boolean;
  minReportSeverity?: ErrorSeverity;
  onError?: (error: ILRMError) => void;
}

export class ErrorHandler {
  private siem?: BoundarySIEM;
  private daemon?: BoundaryDaemon;
  private config: ErrorHandlerConfig;
  private errorCounts: Map<string, number> = new Map();
  private circuitBreakers: Map<string, CircuitBreaker> = new Map();

  constructor(config: ErrorHandlerConfig = {}) {
    this.config = {
      enableSIEMReporting: true,
      enableDaemonProtection: true,
      minReportSeverity: ErrorSeverity.MEDIUM,
      ...config,
    };
    this.siem = config.siem;
    this.daemon = config.daemon;
  }

  async handle(error: Error | ILRMError): Promise<void> {
    // Convert to ILRMError if needed
    const ilrmError =
      error instanceof ILRMError
        ? error
        : new ILRMError(
            error.message,
            ErrorCategory.SYSTEM_INTERNAL,
            ErrorSeverity.MEDIUM,
            {},
            error
          );

    // Track error counts
    const countKey = ilrmError.category;
    this.errorCounts.set(countKey, (this.errorCounts.get(countKey) || 0) + 1);

    // Log locally
    this.logError(ilrmError);

    // Report to SIEM if enabled and severity meets threshold
    if (
      this.config.enableSIEMReporting &&
      this.siem &&
      ilrmError.severity >= (this.config.minReportSeverity || ErrorSeverity.MEDIUM)
    ) {
      await this.reportToSIEM(ilrmError);
    }

    // Check with daemon for security errors
    if (
      this.config.enableDaemonProtection &&
      this.daemon &&
      ilrmError.category.startsWith('security.')
    ) {
      await this.checkDaemonPolicy(ilrmError);
    }

    // Call custom handler if provided
    if (this.config.onError) {
      this.config.onError(ilrmError);
    }
  }

  private logError(error: ILRMError): void {
    const logData = {
      level: this.severityToLogLevel(error.severity),
      timestamp: error.timestamp.toISOString(),
      code: error.code,
      category: error.category,
      message: error.message,
      context: error.context,
    };

    if (error.severity >= ErrorSeverity.HIGH) {
      console.error('[ILRM ERROR]', JSON.stringify(logData, null, 2));
    } else if (error.severity >= ErrorSeverity.MEDIUM) {
      console.warn('[ILRM WARN]', JSON.stringify(logData));
    } else {
      console.info('[ILRM INFO]', JSON.stringify(logData));
    }
  }

  private severityToLogLevel(severity: ErrorSeverity): string {
    if (severity >= ErrorSeverity.CRITICAL) return 'CRITICAL';
    if (severity >= ErrorSeverity.HIGH) return 'ERROR';
    if (severity >= ErrorSeverity.MEDIUM) return 'WARN';
    if (severity >= ErrorSeverity.LOW) return 'INFO';
    return 'DEBUG';
  }

  private async reportToSIEM(error: ILRMError): Promise<void> {
    if (!this.siem) return;

    try {
      const event = error.toSecurityEvent();
      await this.siem.sendEvent(event);
    } catch (siemError) {
      console.error('[ILRM] Failed to report to SIEM:', siemError);
    }
  }

  private async checkDaemonPolicy(error: ILRMError): Promise<void> {
    if (!this.daemon) return;

    try {
      const decision = await this.daemon.checkPolicy({
        action: error.category,
        context: error.context,
        severity: error.severity,
      });

      if (decision === PolicyDecision.DENY) {
        console.error('[ILRM] Daemon policy violation - action blocked');
        // Could trigger additional protective measures here
      }
    } catch (daemonError) {
      console.error('[ILRM] Failed to check daemon policy:', daemonError);
    }
  }

  getErrorStats(): Record<string, number> {
    return Object.fromEntries(this.errorCounts);
  }

  getCircuitBreaker(key: string): CircuitBreaker {
    if (!this.circuitBreakers.has(key)) {
      this.circuitBreakers.set(key, new CircuitBreaker());
    }
    return this.circuitBreakers.get(key)!;
  }
}

// ============================================================================
// Circuit Breaker Pattern
// ============================================================================

export enum CircuitState {
  CLOSED = 'CLOSED',
  OPEN = 'OPEN',
  HALF_OPEN = 'HALF_OPEN',
}

export interface CircuitBreakerConfig {
  failureThreshold?: number;
  resetTimeout?: number;
  halfOpenRequests?: number;
}

export class CircuitBreaker {
  private state: CircuitState = CircuitState.CLOSED;
  private failureCount: number = 0;
  private lastFailureTime?: Date;
  private successCount: number = 0;
  private config: Required<CircuitBreakerConfig>;

  constructor(config: CircuitBreakerConfig = {}) {
    this.config = {
      failureThreshold: config.failureThreshold || 5,
      resetTimeout: config.resetTimeout || 30000, // 30 seconds
      halfOpenRequests: config.halfOpenRequests || 3,
    };
  }

  async execute<T>(fn: () => Promise<T>): Promise<T> {
    if (this.state === CircuitState.OPEN) {
      if (this.shouldAttemptReset()) {
        this.state = CircuitState.HALF_OPEN;
      } else {
        throw new ILRMError(
          'Circuit breaker is open',
          ErrorCategory.SYSTEM_RESOURCE_EXHAUSTED,
          ErrorSeverity.HIGH,
          {},
          undefined,
          true
        );
      }
    }

    try {
      const result = await fn();
      this.onSuccess();
      return result;
    } catch (error) {
      this.onFailure();
      throw error;
    }
  }

  private shouldAttemptReset(): boolean {
    if (!this.lastFailureTime) return true;
    const elapsed = Date.now() - this.lastFailureTime.getTime();
    return elapsed >= this.config.resetTimeout;
  }

  private onSuccess(): void {
    if (this.state === CircuitState.HALF_OPEN) {
      this.successCount++;
      if (this.successCount >= this.config.halfOpenRequests) {
        this.reset();
      }
    }
    this.failureCount = 0;
  }

  private onFailure(): void {
    this.failureCount++;
    this.lastFailureTime = new Date();

    if (this.state === CircuitState.HALF_OPEN) {
      this.state = CircuitState.OPEN;
    } else if (this.failureCount >= this.config.failureThreshold) {
      this.state = CircuitState.OPEN;
    }
  }

  private reset(): void {
    this.state = CircuitState.CLOSED;
    this.failureCount = 0;
    this.successCount = 0;
  }

  getState(): CircuitState {
    return this.state;
  }
}

// ============================================================================
// Retry Logic with Exponential Backoff
// ============================================================================

export interface RetryConfig {
  maxRetries?: number;
  baseDelay?: number;
  maxDelay?: number;
  backoffMultiplier?: number;
  retryableErrors?: ErrorCategory[];
}

export async function withRetry<T>(
  fn: () => Promise<T>,
  config: RetryConfig = {}
): Promise<T> {
  const {
    maxRetries = 3,
    baseDelay = 1000,
    maxDelay = 30000,
    backoffMultiplier = 2,
    retryableErrors = [
      ErrorCategory.NETWORK_TIMEOUT,
      ErrorCategory.NETWORK_CONNECTION_REFUSED,
      ErrorCategory.NETWORK_RPC_ERROR,
      ErrorCategory.ORACLE_UNAVAILABLE,
    ],
  } = config;

  let lastError: Error | undefined;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error as Error;

      // Check if error is retryable
      const isRetryable =
        error instanceof ILRMError
          ? error.retryable || retryableErrors.includes(error.category)
          : true;

      if (!isRetryable || attempt === maxRetries) {
        throw error;
      }

      // Calculate delay with exponential backoff
      const delay = Math.min(
        baseDelay * Math.pow(backoffMultiplier, attempt),
        maxDelay
      );

      // Add jitter (±10%)
      const jitter = delay * 0.1 * (Math.random() * 2 - 1);
      const finalDelay = delay + jitter;

      console.info(
        `[ILRM] Retry attempt ${attempt + 1}/${maxRetries} after ${Math.round(
          finalDelay
        )}ms`
      );

      await new Promise((resolve) => setTimeout(resolve, finalDelay));
    }
  }

  throw lastError;
}

// ============================================================================
// Global Error Handler
// ============================================================================

let globalErrorHandler: ErrorHandler | null = null;

export function initializeErrorHandler(config: ErrorHandlerConfig): ErrorHandler {
  globalErrorHandler = new ErrorHandler(config);
  return globalErrorHandler;
}

export function getErrorHandler(): ErrorHandler {
  if (!globalErrorHandler) {
    globalErrorHandler = new ErrorHandler();
  }
  return globalErrorHandler;
}

export async function handleError(error: Error | ILRMError): Promise<void> {
  return getErrorHandler().handle(error);
}
