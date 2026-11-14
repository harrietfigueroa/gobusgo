// Builds the bytes the refusal cases patch into a fixture. A browser has no
// `Buffer`, so hexadecimal text is parsed here.

const HEX_RADIX = 16
const HEX_DIGITS_PER_BYTE = 2

/** The bytes `hex` spells, two hexadecimal digits a byte. */
export function hexBytes(hex) {
  const byteCount = Math.trunc(hex.length / HEX_DIGITS_PER_BYTE)
  const bytes = new Uint8Array(byteCount)

  for (let index = 0; index < byteCount; index++) {
    const start = index * HEX_DIGITS_PER_BYTE
    const digits = hex.slice(start, start + HEX_DIGITS_PER_BYTE)
    bytes[index] = Number.parseInt(digits, HEX_RADIX)
  }

  return bytes
}
