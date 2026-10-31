// Demo status is determined by the signing key, not by a self-asserted payload field.
const isDemoKey = keyId.startsWith("mcpg-demo-");

if (isDemoKey && !allowDemo) {
  reasons.push("demo receipt not allowed");
  valid = false;
}