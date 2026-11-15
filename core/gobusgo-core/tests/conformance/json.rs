//! A reader of the JSON the shared fixtures hold. The core takes no
//! third-party crate, so this reads the JSON grammar itself: objects, arrays,
//! strings with their escapes, numbers, booleans, and null. A number reads as
//! the double nearest its text, as JavaScript's `JSON.parse` reads it, and the
//! strings `NaN`, `Infinity`, and `-Infinity` stand for the numbers JSON cannot
//! write.

use std::iter::Peekable;
use std::str::Chars;

/// A JSON value.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Number(f64),
    Text(String),
    Array(Vec<Self>),
    Object(Vec<(String, Self)>),
}

/// The deepest nesting of arrays and objects a fixture holds.
const DEPTH_MAX: usize = 64;

/// The value `text` holds, which must be JSON and nothing after it.
pub fn parse(text: &str) -> Value {
    let mut reader = Reader {
        characters: text.chars().peekable(),
    };
    let value = reader.value(0);
    reader.skip_whitespace();
    assert!(
        reader.characters.peek().is_none(),
        "json: text after the value"
    );
    value
}

impl Value {
    /// The value of `key`, which this object must hold.
    pub fn get(&self, key: &str) -> &Self {
        let Self::Object(members) = self else {
            panic!("json: {key} read from a value that is no object: {self:?}");
        };
        let found = members.iter().find(|(name, _)| name == key);
        let Some((_, value)) = found else {
            panic!("json: no member {key}");
        };
        value
    }

    /// The number this value is, or the number one of the strings `NaN`,
    /// `Infinity`, and `-Infinity` stands for.
    pub fn number(&self) -> f64 {
        match self {
            Self::Number(number) => *number,
            Self::Text(text) => match text.as_str() {
                "NaN" => f64::NAN,
                "Infinity" => f64::INFINITY,
                "-Infinity" => f64::NEG_INFINITY,
                _ => panic!("json: {text} stands for no number"),
            },
            _ => panic!("json: {self:?} is no number"),
        }
    }

    /// The text this string holds.
    pub fn text(&self) -> &str {
        let Self::Text(text) = self else {
            panic!("json: {self:?} is no string");
        };
        text
    }

    /// The items of this array.
    pub fn items(&self) -> &[Self] {
        let Self::Array(items) = self else {
            panic!("json: {self:?} is no array");
        };
        items
    }

    /// The numbers of this array, each read by `number`.
    pub fn numbers(&self) -> Vec<f64> {
        self.items().iter().map(Self::number).collect()
    }
}

struct Reader<'text> {
    characters: Peekable<Chars<'text>>,
}

impl Reader<'_> {
    fn value(&mut self, depth: usize) -> Value {
        let inner_depth = depth.checked_add(1).expect("json: a depth fits a usize");
        assert!(inner_depth <= DEPTH_MAX, "json: nested past {DEPTH_MAX}");
        self.skip_whitespace();
        let next = self.characters.peek().copied();
        match next {
            Some('{') => self.object(inner_depth),
            Some('[') => self.array(inner_depth),
            Some('"') => Value::Text(self.string()),
            Some('t') => self.word("true", Value::Bool(true)),
            Some('f') => self.word("false", Value::Bool(false)),
            Some('n') => self.word("null", Value::Null),
            Some(character) if character == '-' || character.is_ascii_digit() => self.number(),
            other => panic!("json: no value starts with {other:?}"),
        }
    }

    fn object(&mut self, depth: usize) -> Value {
        self.expect('{');
        let mut members = Vec::new();
        self.skip_whitespace();
        if self.characters.peek() == Some(&'}') {
            self.characters.next();
            return Value::Object(members);
        }
        loop {
            self.skip_whitespace();
            let key = self.string();
            self.skip_whitespace();
            self.expect(':');
            let value = self.value(depth);
            let is_new_key = members.iter().all(|(name, _)| *name != key);
            assert!(is_new_key, "json: the key {key} appears twice in an object");
            members.push((key, value));
            self.skip_whitespace();
            match self.characters.next() {
                Some(',') => {}
                Some('}') => return Value::Object(members),
                other => panic!("json: an object continues with {other:?}"),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Value {
        self.expect('[');
        let mut items = Vec::new();
        self.skip_whitespace();
        if self.characters.peek() == Some(&']') {
            self.characters.next();
            return Value::Array(items);
        }
        loop {
            items.push(self.value(depth));
            self.skip_whitespace();
            match self.characters.next() {
                Some(',') => {}
                Some(']') => return Value::Array(items),
                other => panic!("json: an array continues with {other:?}"),
            }
        }
    }

    fn string(&mut self) -> String {
        self.expect('"');
        let mut text = String::new();
        loop {
            match self.characters.next() {
                Some('"') => return text,
                Some('\\') => text.push(self.escape()),
                Some(character) => {
                    // JSON forbids only U+0000 to U+001F unescaped in a string.
                    assert!(
                        character >= '\u{20}',
                        "json: a control character in a string"
                    );
                    text.push(character);
                }
                None => panic!("json: a string never closes"),
            }
        }
    }

    fn escape(&mut self) -> char {
        match self.characters.next() {
            Some('"') => '"',
            Some('\\') => '\\',
            Some('/') => '/',
            Some('b') => '\u{8}',
            Some('f') => '\u{c}',
            Some('n') => '\n',
            Some('r') => '\r',
            Some('t') => '\t',
            Some('u') => self.unicode_escape(),
            other => panic!("json: no escape {other:?}"),
        }
    }

    // A `\u` escape, and the low half that follows a high surrogate.
    fn unicode_escape(&mut self) -> char {
        let unit = self.hex_unit();
        let is_high_surrogate = (0xD800..0xDC00).contains(&unit);
        let mut units = vec![unit];
        if is_high_surrogate {
            self.expect('\\');
            self.expect('u');
            units.push(self.hex_unit());
        }
        let decoded: Vec<_> = char::decode_utf16(units).collect();
        let [Ok(character)] = decoded.as_slice() else {
            panic!("json: an escape names no character: {decoded:?}");
        };
        *character
    }

    fn hex_unit(&mut self) -> u16 {
        let digits: String = self.characters.by_ref().take(4).collect();
        assert_eq!(digits.len(), 4, "json: a short escape");
        u16::from_str_radix(&digits, 16).expect("json: an escape is hexadecimal")
    }

    fn number(&mut self) -> Value {
        let mut text = String::new();
        self.take_if(&mut text, |character| character == '-');
        let is_zero = self.take_if(&mut text, |character| character == '0');
        if is_zero {
            let leading_digit = self.characters.peek().copied();
            assert!(
                !leading_digit.is_some_and(|character| character.is_ascii_digit()),
                "json: a number with a leading zero"
            );
        } else {
            let integer_count = self.digits(&mut text);
            assert!(integer_count > 0, "json: a number without digits");
        }
        let has_fraction = self.take_if(&mut text, |character| character == '.');
        if has_fraction {
            let fraction_count = self.digits(&mut text);
            assert!(fraction_count > 0, "json: a decimal point without digits");
        }
        let has_exponent =
            self.take_if(&mut text, |character| character == 'e' || character == 'E');
        if has_exponent {
            self.take_if(&mut text, |character| character == '+' || character == '-');
            let exponent_count = self.digits(&mut text);
            assert!(exponent_count > 0, "json: an exponent without digits");
        }
        // Rust reads a decimal as the nearest double, as JavaScript does.
        let number = text.parse::<f64>().expect("json: a number");
        Value::Number(number)
    }

    // Moves the next character into `text` where `accepts` takes it, and says
    // whether it did.
    fn take_if(&mut self, text: &mut String, accepts: impl Fn(char) -> bool) -> bool {
        let next = self.characters.peek().copied();
        let Some(character) = next.filter(|character| accepts(*character)) else {
            return false;
        };
        text.push(character);
        self.characters.next();
        true
    }

    // Moves a run of decimal digits into `text`, and counts them.
    fn digits(&mut self, text: &mut String) -> usize {
        let mut count = 0_usize;
        while self.take_if(text, |character| character.is_ascii_digit()) {
            count = count
                .checked_add(1)
                .expect("json: a digit count fits a usize");
        }
        count
    }

    fn word(&mut self, word: &str, value: Value) -> Value {
        for expected in word.chars() {
            self.expect(expected);
        }
        value
    }

    fn expect(&mut self, expected: char) {
        let found = self.characters.next();
        assert_eq!(found, Some(expected), "json: expected {expected:?}");
    }

    fn skip_whitespace(&mut self) {
        while let Some(&character) = self.characters.peek() {
            let is_whitespace = matches!(character, ' ' | '\t' | '\n' | '\r');
            if !is_whitespace {
                break;
            }
            self.characters.next();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Value, parse};

    // Each case reads one JSON text and compares the value with the one the
    // text writes, covering every kind of value, the escapes, and numbers
    // with a fraction and an exponent.
    #[test]
    fn reads_each_kind_of_value() {
        let cases = [
            ("null", Value::Null),
            ("true", Value::Bool(true)),
            (" false ", Value::Bool(false)),
            ("-0.25e2", Value::Number(-25.0)),
            ("1e-7", Value::Number(1e-7)),
            (
                r#""a\"b\\c\/\né🚌""#,
                Value::Text("a\"b\\c/\né\u{1F68C}".to_owned()),
            ),
            ("[]", Value::Array(vec![])),
            (
                "[1, [2]]",
                Value::Array(vec![
                    Value::Number(1.0),
                    Value::Array(vec![Value::Number(2.0)]),
                ]),
            ),
            ("{}", Value::Object(vec![])),
            (
                r#"{"a": {"b": null}}"#,
                Value::Object(vec![(
                    "a".to_owned(),
                    Value::Object(vec![("b".to_owned(), Value::Null)]),
                )]),
            ),
        ];
        for (text, expected) in cases {
            assert_eq!(parse(text), expected, "text: {text}");
        }
    }

    #[test]
    fn reads_the_numbers_json_cannot_write() {
        let value = parse(r#"["NaN", "Infinity", "-Infinity", 3]"#);
        let numbers = value.numbers();
        assert!(numbers[0].is_nan());
        assert_eq!(&numbers[1..], &[f64::INFINITY, f64::NEG_INFINITY, 3.0]);
    }

    #[test]
    #[should_panic]
    fn refuses_text_after_the_value() {
        let _ = parse("1 2");
    }

    #[test]
    #[should_panic]
    fn refuses_an_unclosed_array() {
        let _ = parse("[1, 2");
    }

    #[test]
    #[should_panic]
    fn refuses_a_leading_zero() {
        let _ = parse("01");
    }

    #[test]
    #[should_panic]
    fn refuses_a_decimal_point_without_digits() {
        let _ = parse("1.");
    }

    #[test]
    #[should_panic]
    fn refuses_a_key_twice_in_an_object() {
        let _ = parse(r#"{"a": 1, "a": 2}"#);
    }

    #[test]
    #[should_panic]
    fn refuses_an_unescaped_control_character() {
        let _ = parse("\"a\u{1f}b\"");
    }

    // Only U+0000 to U+001F are forbidden, so DEL and the C1 controls read.
    #[test]
    fn reads_delete_and_the_c1_controls() {
        let value = parse("\"\u{7f}\u{85}\"");
        assert_eq!(value, Value::Text("\u{7f}\u{85}".to_owned()));
    }
}
