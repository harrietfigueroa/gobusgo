//! The offline logic every platform runs. Everything here is pure and
//! synchronous and does no IO, so each platform's driver owns every fetch, every
//! file's bytes, and every lifecycle, and a binding holds no handle to free.

/// The version of the core, which a binding reports so a page or an app can name
/// the core it loaded.
#[must_use]
pub const fn core_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    // The version comes from the manifest, so the test checks that it is a
    // nonempty dotted version rather than repeating its value.
    #[test]
    fn core_version_is_three_dotted_numbers() {
        let parts: Vec<&str> = super::core_version().split('.').collect();
        assert_eq!(parts.len(), 3, "version: {}", super::core_version());
        for part in parts {
            assert!(part.parse::<u32>().is_ok(), "part: {part}");
        }
    }
}
