// Checks the facade's refusal of a document that does not preload the core's
// module: importing the facade with no preload in the head rejects with the
// AssertionError. Each test file runs in a page of its own, so this one's
// import is the facade's first.

import {expect, test} from "vitest"
import {AssertionError} from "../../../assets/js/core/assert.js"

test("importing the facade without the core's preload rejects", async () => {
  const importing = import("../../../assets/js/core.js")

  await expect(importing).rejects.toThrow(AssertionError)
})
