//! The core's binding for the web. Each export converts its arguments and result
//! across wasm-bindgen and holds no logic of its own.

use wasm_bindgen::prelude::wasm_bindgen;

/// The version of the core this module was built from.
#[wasm_bindgen(js_name = coreVersion)]
#[must_use]
pub fn core_version() -> String {
    gobusgo_core::core_version().to_owned()
}

#[cfg(test)]
mod tests {
    // The binding passes the core's value through unchanged.
    #[test]
    fn core_version_is_the_core_version() {
        assert_eq!(super::core_version(), gobusgo_core::core_version());
    }
}
