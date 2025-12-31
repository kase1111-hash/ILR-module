/**
 * Type declarations for optional ZK circuit packages
 * These packages are dynamically imported and may not always be present
 */

declare module 'circomlibjs' {
  export function buildPoseidon(): Promise<{
    (inputs: any[]): any;
    F: {
      e: (input: bigint) => any;
      toObject: (hash: any) => bigint;
    };
  }>;
}

declare module 'snarkjs' {
  export namespace groth16 {
    function fullProve(
      input: Record<string, string>,
      wasmPath: string,
      zkeyPath: string
    ): Promise<{
      proof: any;
      publicSignals: string[];
    }>;

    function verify(
      vkey: any,
      publicSignals: string[],
      proof: any
    ): Promise<boolean>;
  }
}
