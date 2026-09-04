import assert from 'node:assert/strict'
import test from 'node:test'

import { backendRestartDelay } from '../src/main/backendRestartPolicy.ts'

test('unexpected backend exits use bounded exponential-style recovery', () => {
  assert.equal(backendRestartDelay(0), 1_000)
  assert.equal(backendRestartDelay(1), 3_000)
  assert.equal(backendRestartDelay(2), 10_000)
  assert.equal(backendRestartDelay(3), null)
})

test('invalid restart attempts fail closed', () => {
  assert.equal(backendRestartDelay(-1), null)
  assert.equal(backendRestartDelay(0.5), null)
})
