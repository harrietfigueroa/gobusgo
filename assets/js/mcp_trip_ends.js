// What the trip planner app decides of one end of a trip, as pure functions:
// from the results of the "Where to?" search for the rider's words, whether
// the words name exactly one end, name several the rider picks between, or
// name none. Nothing here reads the document, the network, or a clock.
//
// An end is resolved on its own only when the search finds one result in all.
// A name two results share, a street in two cities or a stop beside the
// place it is named for, is the rider's to choose, since a wrong end routes a
// different trip with no sign that it did.

import {assertCondition} from "./assert.js"
import {ChoiceKind, suggestionList} from "./where_to.js"

/** The kinds of what the search decides of an end's words. */
export const ResolutionKind = Object.freeze({resolved: "resolved", choices: "choices", none: "none"})

function endOptionsOf(groups) {
  const options = []

  for (const group of groups) {
    for (const option of group.options) {
      assertCondition(option.choice.kind === ChoiceKind.end, "trip ends: a result chooses something other than an end: " + option.choice.kind)
      options.push(option)
    }
  }

  return options
}

/**
 * What the search says of the end `end`, `TripEnd.from` or `TripEnd.to`, for
 * `text`, the rider's non-empty words, given `found`, the results of the
 * search as `where_to_files.js` returns them. A ResolutionKind member:
 * `resolved` with the one `option` and its `end`, the value the planner
 * takes; `choices` with `groups`, the list's groups of options in its order,
 * each option's `choice.end` the end choosing it sets; or `none`.
 */
export function resolution({text, end, found}) {
  assertCondition(text.trim() !== "", "trip ends: the words of an end are blank")
  const list = suggestionList({text, end, recents: [], favorites: [], found})
  const options = endOptionsOf(list.groups)

  if (options.length === 0) {
    return {kind: ResolutionKind.none}
  }

  if (options.length === 1) {
    const [option] = options
    return {kind: ResolutionKind.resolved, option, end: option.choice.end}
  }

  return {kind: ResolutionKind.choices, groups: list.groups, isCredited: list.isCredited}
}
