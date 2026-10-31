// Fix: do not normalize JSON-RPC params; preserve the original wire shape
// so inputHash is injective over distinct wire messages.

export function serverInput(msg: unknown): unknown {
  // Return the message unchanged. Previously array params were wrapped as
  // { params: [...] }, colliding with an object params of { params: [...] }.
  return msg;
}