// =============================================================================
// Test helpers: mock events with controlled transaction, block and log index
// =============================================================================

import { newMockEvent } from "matchstick-as/assembly/index";
import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";

export const ILRM_ADDRESS = Address.fromString("0x00000000000000000000000000000000000000a1");
export const TREASURY_ADDRESS = Address.fromString("0x00000000000000000000000000000000000000a2");
export const ORACLE_ADDRESS = Address.fromString("0x00000000000000000000000000000000000000a3");
export const L3_ADDRESS = Address.fromString("0x00000000000000000000000000000000000000a4");
export const REGISTRY_ADDRESS = Address.fromString("0x00000000000000000000000000000000000000a5");

export const ALICE = Address.fromString("0x000000000000000000000000000000000000a11c");
export const BOB = Address.fromString("0x0000000000000000000000000000000000000b0b");
export const CAROL = Address.fromString("0x00000000000000000000000000000000000c0001");
export const OPERATOR = Address.fromString("0x00000000000000000000000000000000000000e1");
export const RELAYER = Address.fromString("0x00000000000000000000000000000000000000e2");

// -----------------------------------------------------------------------------
// Current transaction context (AssemblyScript closures cannot capture locals, so
// tests drive this module-level state)
// -----------------------------------------------------------------------------

let txHash: Bytes = word(1);
let blockNumber: BigInt = BigInt.fromI32(1);
let blockTimestamp: BigInt = BigInt.fromI32(1000);
let txFrom: Address = OPERATOR;
let txTo: Address = ILRM_ADDRESS;
let txInput: Bytes = Bytes.empty();
let txValue: BigInt = BigInt.zero();
let logIndex: i32 = 0;

/** bytes32 with `n` in the low bytes */
export function word(n: i32): Bytes {
  let hex = n.toString(16);
  while (hex.length < 64) hex = "0" + hex;
  return Bytes.fromHexString("0x" + hex);
}

/** Start a new transaction: events built afterwards share its hash, block and timestamp */
export function beginTx(n: i32, timestamp: i32): void {
  txHash = word(0x10000 + n);
  blockNumber = BigInt.fromI32(n);
  blockTimestamp = BigInt.fromI32(timestamp);
  txFrom = OPERATOR;
  txTo = Address.zero(); // indirect call unless setCall() says otherwise
  txInput = Bytes.empty();
  txValue = BigInt.zero();
}

/** Make the current transaction a direct call of `to` with `input` and `value` */
export function setCall(from: Address, to: Address, input: Bytes, value: BigInt): void {
  txFrom = from;
  txTo = to;
  txInput = input;
  txValue = value;
}

export function currentTx(): Bytes {
  return txHash;
}

/** A mock log emitted by `address` in the current transaction */
export function mockEvent(address: Address, params: Array<ethereum.EventParam>): ethereum.Event {
  const event = newMockEvent();
  event.address = address;
  event.logIndex = BigInt.fromI32(logIndex++);
  event.parameters = params;
  event.block.number = blockNumber;
  event.block.timestamp = blockTimestamp;
  event.transaction.hash = txHash;
  event.transaction.from = txFrom;
  event.transaction.to = txTo;
  event.transaction.input = txInput;
  event.transaction.value = txValue;
  return event;
}

// -----------------------------------------------------------------------------
// Event parameters
// -----------------------------------------------------------------------------

export function pAddr(name: string, value: Address): ethereum.EventParam {
  return new ethereum.EventParam(name, ethereum.Value.fromAddress(value));
}

export function pUint(name: string, value: BigInt): ethereum.EventParam {
  return new ethereum.EventParam(name, ethereum.Value.fromUnsignedBigInt(value));
}

export function pInt(name: string, value: i32): ethereum.EventParam {
  return new ethereum.EventParam(name, ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(value)));
}

export function pB32(name: string, value: Bytes): ethereum.EventParam {
  return new ethereum.EventParam(name, ethereum.Value.fromFixedBytes(value));
}

export function pBytes(name: string, value: Bytes): ethereum.EventParam {
  return new ethereum.EventParam(name, ethereum.Value.fromBytes(value));
}

export function pB32Array(name: string, value: Array<Bytes>): ethereum.EventParam {
  return new ethereum.EventParam(name, ethereum.Value.fromFixedBytesArray(value));
}

export function pStr(name: string, value: string): ethereum.EventParam {
  return new ethereum.EventParam(name, ethereum.Value.fromString(value));
}

export function pBool(name: string, value: boolean): ethereum.EventParam {
  return new ethereum.EventParam(name, ethereum.Value.fromBoolean(value));
}

export function bi(value: i32): BigInt {
  return BigInt.fromI32(value);
}

/** Decimal string -> BigInt (for wei amounts) */
export function wei(value: string): BigInt {
  return BigInt.fromString(value);
}
