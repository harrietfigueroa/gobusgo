// A rule that keeps a module synchronous: it reports every async function,
// every await, every dynamic import, every call of a promise's methods, and
// every reference to a global that starts work finishing later. A module it
// passes takes values and returns values, so the host on each platform owns
// the IO and the core can be ported as it is.

// Globals that start work finishing later, or stand for it, as the browser
// and node name them. A binding of the same name declared in the module
// shadows the global and is not reported.
const ASYNC_GLOBALS = new Set([
  "AbortSignal",
  "BroadcastChannel",
  "CompressionStream",
  "DecompressionStream",
  "EventSource",
  "MessageChannel",
  "Promise",
  "ReadableStream",
  "SharedWorker",
  "TransformStream",
  "WebSocket",
  "Worker",
  "WritableStream",
  "XMLHttpRequest",
  "caches",
  "fetch",
  "indexedDB",
  "queueMicrotask",
  "requestAnimationFrame",
  "requestIdleCallback",
  "setImmediate",
  "setInterval",
  "setTimeout"
])

const PROMISE_METHODS = new Set(["then", "catch", "finally"])

function isPromiseMethodCall(node) {
  const callee = node.callee
  const isMember = callee.type === "MemberExpression"
  const isNamed = isMember && !callee.computed
  const isIdentifier = isNamed && callee.property.type === "Identifier"
  return isIdentifier && PROMISE_METHODS.has(callee.property.name)
}

const rule = {
  meta: {
    type: "problem",
    schema: [],
    messages: {
      asyncFunction: "The core does no async work: this function is async.",
      await: "The core does no async work: this awaits.",
      forAwait: "The core does no async work: this loop awaits each value.",
      dynamicImport: "The core does no async work: a dynamic import loads later.",
      promiseMethod: "The core does no async work: `{{name}}` waits on a promise.",
      asyncGlobal: "The core does no async work: `{{name}}` starts work that finishes later."
    }
  },
  create(context) {
    function reportAsyncFunction(node) {
      if (node.async) {
        context.report({node, messageId: "asyncFunction"})
      }
    }

    return {
      FunctionDeclaration: reportAsyncFunction,
      FunctionExpression: reportAsyncFunction,
      ArrowFunctionExpression: reportAsyncFunction,
      AwaitExpression(node) {
        context.report({node, messageId: "await"})
      },
      ForOfStatement(node) {
        if (node.await) {
          context.report({node, messageId: "forAwait"})
        }
      },
      ImportExpression(node) {
        context.report({node, messageId: "dynamicImport"})
      },
      CallExpression(node) {
        if (isPromiseMethodCall(node)) {
          context.report({node, messageId: "promiseMethod", data: {name: node.callee.property.name}})
        }
      },
      // A reference to a global reaches the global scope two ways: a
      // built-in of the language, such as `Promise`, is a variable there with
      // no definition, and a host's global, such as `fetch`, resolves to no
      // variable and sits in `through`. A binding the module declares
      // resolves to it, so a parameter named `fetch` is neither.
      "Program:exit"(node) {
        const scope = context.sourceCode.getScope(node)
        const references = Array.from(scope.through)

        for (const variable of scope.variables) {
          const isBuiltIn = variable.defs.length === 0

          if (isBuiltIn) {
            for (const reference of variable.references) {
              references.push(reference)
            }
          }
        }

        for (const reference of references) {
          const {name} = reference.identifier

          if (ASYNC_GLOBALS.has(name)) {
            context.report({node: reference.identifier, messageId: "asyncGlobal", data: {name}})
          }
        }
      }
    }
  }
}

export default {rules: {"no-async-work": rule}}
