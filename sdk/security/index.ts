/**
 * NatLangChain ILRM - Security Module
 *
 * Comprehensive security integration layer providing:
 * - Error handling with SIEM reporting
 * - Boundary-SIEM integration for event logging
 * - Boundary-Daemon integration for connection protection
 * - Circuit breaker and retry patterns
 *
 * Usage:
 * ```typescript
 * import { initializeSecurity, getSecurityManager } from '@ilrm/security';
 *
 * // Initialize on startup
 * await initializeSecurity({
 *   siem: {
 *     enabled: true,
 *     endpoint: 'https://siem.boundary.io',
 *     apiKey: process.env.SIEM_API_KEY
 *   },
 *   daemon: {
 *     enabled: true,
 *     socketPath: '/var/run/boundary-daemon/daemon.sock'
 *   }
 * });
 *
 * // Use in application
 * const manager = getSecurityManager();
 * const siem = manager.getSIEM();
 * const daemon = manager.getDaemon();
 *
 * // Log security event
 * await siem?.logSecurityEvent('dispute.created', 'New dispute created', Severity.INFO, {
 *   disputeId: '12345'
 * });
 *
 * // Check policy before action
 * const allowed = await daemon?.checkDisputeAction('12345', 'submit', '0x...');
 * ```
 */

// ============================================================================
// Error Handling
// ============================================================================

export {
  // Enums
  ErrorSeverity,
  ErrorCategory,
  CircuitState,
  // Interfaces
  type ErrorContext,
  type ErrorHandlerConfig,
  type CircuitBreakerConfig,
  type RetryConfig,
  // Classes
  ILRMError,
  ContractError,
  NetworkError,
  SecurityError,
  ValidationError,
  OracleError,
  BridgeError,
  ErrorHandler,
  CircuitBreaker,
  // Functions
  withRetry,
  initializeErrorHandler,
  getErrorHandler,
  handleError,
} from './errors';

// ============================================================================
// Boundary-SIEM Integration
// ============================================================================

export {
  // Enums
  Severity,
  // Interfaces
  type EventSource,
  type SecurityEvent,
  type SIEMConfig,
  type SIEMResponse,
  type AlertCallback,
  type SecurityAlert,
  // Classes
  BoundarySIEM,
  // Functions
  createSIEMClient,
} from './boundary-siem';

// ============================================================================
// Boundary-Daemon Integration
// ============================================================================

export {
  // Enums
  PolicyDecision,
  RuleAction,
  // Interfaces
  type PolicyContext,
  type PolicyResult,
  type ConnectionRule,
  type DaemonConfig,
  type AuditEvent,
  type DaemonStatus,
  // Classes
  BoundaryDaemon,
  MockBoundaryDaemon,
  // Functions
  createDaemonClient,
} from './boundary-daemon';

// ============================================================================
// Configuration and Management
// ============================================================================

export {
  // Interfaces
  type SecurityConfig,
  // Classes
  SecurityManager,
  // Functions
  loadConfigFromEnv,
  getSecurityManager,
  initializeSecurity,
  shutdownSecurity,
  createTestSecurityManager,
} from './config';

// ============================================================================
// Re-exports for convenience
// ============================================================================

// Default export: Security Manager
import { SecurityManager } from './config';
export default SecurityManager;
