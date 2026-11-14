// The implementations of the core every conformance case runs against. Each
// entry names an implementation and holds its modules under the names the
// cases read, so a case takes one entry as its parameter and never imports an
// implementation itself.

import {AssertionError} from "../../assets/js/core/assert.js"
import * as angles from "../../assets/js/core/math/angles.js"
import * as colorContrast from "../../assets/js/core/math/color_contrast.js"
import * as geodesy from "../../assets/js/core/math/geodesy.js"
import * as interpolation from "../../assets/js/core/math/interpolation.js"
import * as polyline from "../../assets/js/core/math/polyline.js"
import * as packedContainer from "../../assets/js/core/packed_container.js"
import * as routingNames from "../../assets/js/core/routing_names.js"
import * as routingSnapshot from "../../assets/js/core/routing_snapshot.js"

/** One entry per implementation of the core, each with its modules. */
export const IMPLEMENTATIONS = Object.freeze([
  Object.freeze({
    name: "javascript",
    AssertionError,
    angles,
    colorContrast,
    geodesy,
    interpolation,
    packedContainer,
    polyline,
    routingNames,
    routingSnapshot
  })
])
