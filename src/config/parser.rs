use super::ScientificDiagnostic;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) enum Value {
    Atom(String),
    Object(BTreeMap<String, Self>),
    Array(Vec<Self>),
}

impl Value {
    pub(super) fn object(
        &self,
        field: &str,
    ) -> Result<&BTreeMap<String, Self>, ScientificDiagnostic> {
        match self {
            Self::Object(value) => Ok(value),
            _ => Err(ScientificDiagnostic::new(field, "expected an object")),
        }
    }

    pub(super) fn array(&self, field: &str) -> Result<&[Self], ScientificDiagnostic> {
        match self {
            Self::Array(value) => Ok(value),
            _ => Err(ScientificDiagnostic::new(field, "expected an array")),
        }
    }
}

pub(super) struct Parser<'a> {
    input: &'a [u8],
    position: usize,
}

impl<'a> Parser<'a> {
    pub(super) const fn new(input: &'a str) -> Self {
        Self {
            input: input.as_bytes(),
            position: 0,
        }
    }

    pub(super) fn parse(mut self) -> Result<Value, ScientificDiagnostic> {
        self.skip_space_and_comments()?;
        let value = self.value()?;
        self.skip_space_and_comments()?;
        if self.position == self.input.len() {
            Ok(value)
        } else {
            self.error("unexpected data after configuration")
        }
    }

    fn value(&mut self) -> Result<Value, ScientificDiagnostic> {
        self.skip_space_and_comments()?;
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'\'' | b'"') => self.quoted().map(Value::Atom),
            Some(_) => self.atom().map(Value::Atom),
            None => self.error("expected a value"),
        }
    }

    fn object(&mut self) -> Result<Value, ScientificDiagnostic> {
        self.expect(b'{')?;
        let mut values = BTreeMap::new();
        loop {
            self.skip_space_and_comments()?;
            if self.consume(b'}') {
                break;
            }
            let key = match self.peek() {
                Some(b'\'' | b'"') => self.quoted()?,
                Some(_) => self.atom()?,
                None => return self.error("unterminated object"),
            };
            self.skip_space_and_comments()?;
            let _ = self.consume(b'=') || self.consume(b':');
            self.skip_space_and_comments()?;
            let value = self.value()?;
            if values.insert(key.clone(), value).is_some() {
                return self.error(&format!("duplicate object field {key:?}"));
            }
            self.skip_space_and_comments()?;
            let _ = self.consume(b',');
        }
        Ok(Value::Object(values))
    }

    fn array(&mut self) -> Result<Value, ScientificDiagnostic> {
        self.expect(b'[')?;
        let mut values = Vec::new();
        loop {
            self.skip_space_and_comments()?;
            if self.consume(b']') {
                break;
            }
            values.push(self.value()?);
            self.skip_space_and_comments()?;
            let _ = self.consume(b',');
        }
        Ok(Value::Array(values))
    }

    fn quoted(&mut self) -> Result<String, ScientificDiagnostic> {
        let quote = self
            .next()
            .ok_or_else(|| self.diagnostic("expected quoted value"))?;
        let mut result = Vec::new();
        loop {
            match self.next() {
                Some(value) if value == quote => {
                    return String::from_utf8(result)
                        .map_err(|_| self.diagnostic("quoted value is not UTF-8"));
                }
                Some(b'\\') => {
                    let escaped = self
                        .next()
                        .ok_or_else(|| self.diagnostic("unterminated escape"))?;
                    match escaped {
                        b'n' => result.push(b'\n'),
                        b'r' => result.push(b'\r'),
                        b't' => result.push(b'\t'),
                        b'\\' => result.push(b'\\'),
                        b'\'' => result.push(b'\''),
                        b'"' => result.push(b'"'),
                        _ => return self.error("unsupported string escape"),
                    }
                }
                Some(value) => result.push(value),
                None => return self.error("unterminated quoted value"),
            }
        }
    }

    fn atom(&mut self) -> Result<String, ScientificDiagnostic> {
        let start = self.position;
        while let Some(value) = self.peek() {
            if value.is_ascii_whitespace()
                || matches!(value, b'{' | b'}' | b'[' | b']' | b'=' | b':' | b',')
            {
                break;
            }
            self.position += 1;
        }
        if start == self.position {
            self.error("expected a token")
        } else {
            String::from_utf8(self.input[start..self.position].to_vec())
                .map_err(|_| self.diagnostic("configuration token is not UTF-8"))
        }
    }

    fn skip_space_and_comments(&mut self) -> Result<(), ScientificDiagnostic> {
        loop {
            while self.peek().is_some_and(|value| value.is_ascii_whitespace()) {
                self.position += 1;
            }
            if self.peek() == Some(b'#') {
                while self.next().is_some_and(|value| value != b'\n') {}
                continue;
            }
            if self.peek() == Some(b'/') && self.input.get(self.position + 1) == Some(&b'*') {
                self.position += 2;
                while !(self.peek() == Some(b'*')
                    && self.input.get(self.position + 1) == Some(&b'/'))
                {
                    if self.next().is_none() {
                        return self.error("unterminated block comment");
                    }
                }
                self.position += 2;
                continue;
            }
            return Ok(());
        }
    }

    fn expect(&mut self, expected: u8) -> Result<(), ScientificDiagnostic> {
        if self.consume(expected) {
            Ok(())
        } else {
            self.error(&format!("expected {:?}", char::from(expected)))
        }
    }

    fn consume(&mut self, expected: u8) -> bool {
        if self.peek() == Some(expected) {
            self.position += 1;
            true
        } else {
            false
        }
    }

    fn peek(&self) -> Option<u8> {
        self.input.get(self.position).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let value = self.peek()?;
        self.position += 1;
        Some(value)
    }

    fn diagnostic(&self, message: &str) -> ScientificDiagnostic {
        ScientificDiagnostic::new(
            "configuration",
            format!("byte {}: {message}", self.position),
        )
    }

    fn error<T>(&self, message: &str) -> Result<T, ScientificDiagnostic> {
        Err(self.diagnostic(message))
    }
}
