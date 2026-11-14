//! The core's binding for Swift and Kotlin. Each export converts its arguments
//! and result across uniffi and holds no logic of its own.

uniffi::setup_scaffolding!();

/// The version of the core this library was built from.
#[uniffi::export]
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
