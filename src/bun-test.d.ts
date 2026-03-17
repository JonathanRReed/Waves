declare module 'bun:test' {
  export function afterEach(callback: () => void | Promise<void>): void
  export function describe(name: string, callback: () => void | Promise<void>): void
  export function test(name: string, callback: () => void | Promise<void>): void
  export const expect: {
    (value: unknown): {
      toEqual(expected: unknown): void
    }
  }
}
