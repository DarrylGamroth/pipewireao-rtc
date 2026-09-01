use std::ffi::{c_char, c_int, CStr};
use std::marker::PhantomData;
use std::ptr::NonNull;

#[repr(C)]
struct RawCursor {
    _private: [u8; 0],
}

#[derive(Clone, Copy)]
#[repr(C)]
struct RawToken {
    data: *const c_char,
    size: usize,
    kind: c_int,
}

#[repr(C)]
struct RawEntry {
    key: *const c_char,
    key_size: usize,
    value: RawToken,
}

#[derive(Clone, Copy)]
#[repr(C)]
struct RawError {
    line: c_int,
    column: c_int,
    reason: *const c_char,
}

unsafe extern "C" {
    fn pipewireao_rtc_spa_json_root_object(
        data: *const c_char,
        size: usize,
        error: *mut RawError,
    ) -> *mut RawCursor;
    fn pipewireao_rtc_spa_json_object(
        document: *const c_char,
        data: *const c_char,
        size: usize,
        error: *mut RawError,
    ) -> *mut RawCursor;
    fn pipewireao_rtc_spa_json_array(
        document: *const c_char,
        data: *const c_char,
        size: usize,
        error: *mut RawError,
    ) -> *mut RawCursor;
    fn pipewireao_rtc_spa_json_array_next(
        cursor: *mut RawCursor,
        token: *mut RawToken,
        error: *mut RawError,
    ) -> c_int;
    fn pipewireao_rtc_spa_json_object_next(
        cursor: *mut RawCursor,
        entry: *mut RawEntry,
        error: *mut RawError,
    ) -> c_int;
    fn pipewireao_rtc_spa_json_parse_string(
        data: *const c_char,
        size: usize,
        result: *mut c_char,
        result_size: usize,
        written: *mut usize,
    ) -> c_int;
    fn pipewireao_rtc_spa_json_cursor_destroy(cursor: *mut RawCursor);
}

const SCALAR: c_int = 1;
const OBJECT: c_int = 2;
const ARRAY: c_int = 3;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct SyntaxError {
    pub(crate) line: c_int,
    pub(crate) column: c_int,
    pub(crate) reason: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TokenKind {
    Scalar,
    Object,
    Array,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Token<'document> {
    document: &'document str,
    text: &'document str,
    kind: TokenKind,
}

impl<'document> Token<'document> {
    pub(crate) const fn is_object(self) -> bool {
        matches!(self.kind, TokenKind::Object)
    }

    pub(crate) const fn is_array(self) -> bool {
        matches!(self.kind, TokenKind::Array)
    }

    pub(crate) fn scalar(self) -> Result<String, SyntaxError> {
        if self.kind != TokenKind::Scalar {
            return Err(type_error(self, "scalar value"));
        }
        let mut result = vec![0_u8; self.text.len() + 1];
        let mut written = 0;
        // SAFETY: The token span was returned by SPA for this live document,
        // result has token length plus one byte as required by
        // spa_json_parse_stringn, and written points to initialized storage.
        let status = unsafe {
            pipewireao_rtc_spa_json_parse_string(
                self.text.as_ptr().cast(),
                self.text.len(),
                result.as_mut_ptr().cast(),
                result.len(),
                &mut written,
            )
        };
        if status <= 0 || written >= result.len() {
            return Err(SyntaxError {
                line: 0,
                column: 0,
                reason: "PipeWire could not decode the scalar value".to_owned(),
            });
        }
        result.truncate(written);
        String::from_utf8(result).map_err(|_| SyntaxError {
            line: 0,
            column: 0,
            reason: "PipeWire returned a scalar value that is not UTF-8".to_owned(),
        })
    }

    pub(crate) fn object(self) -> Result<Cursor<'document>, SyntaxError> {
        if self.kind != TokenKind::Object {
            return Err(type_error(self, "object"));
        }
        Cursor::container(self.document, self.text, ContainerKind::Object)
    }

    pub(crate) fn array(self) -> Result<Cursor<'document>, SyntaxError> {
        if self.kind != TokenKind::Array {
            return Err(type_error(self, "array"));
        }
        Cursor::container(self.document, self.text, ContainerKind::Array)
    }
}

#[derive(Clone, Copy)]
enum ContainerKind {
    Object,
    Array,
}

pub(crate) struct Cursor<'document> {
    raw: NonNull<RawCursor>,
    document: &'document str,
    _not_send_or_sync: PhantomData<*mut ()>,
}

pub(crate) struct Entry<'document> {
    pub(crate) key: String,
    pub(crate) value: Token<'document>,
}

impl<'document> Cursor<'document> {
    pub(crate) fn root_object(document: &'document str) -> Result<Self, SyntaxError> {
        let mut error = empty_error();
        // SAFETY: document is an immutable byte span that outlives the cursor.
        // SPA reads exactly document.len() bytes and the returned cursor is
        // uniquely owned by this wrapper.
        let raw = unsafe {
            pipewireao_rtc_spa_json_root_object(
                document.as_ptr().cast(),
                document.len(),
                &mut error,
            )
        };
        Self::from_raw(raw, document, error)
    }

    fn container(
        document: &'document str,
        text: &'document str,
        kind: ContainerKind,
    ) -> Result<Self, SyntaxError> {
        let mut error = empty_error();
        // SAFETY: text is a token span within document returned by SPA. Both
        // spans outlive the returned cursor, which this wrapper uniquely owns.
        let raw = unsafe {
            match kind {
                ContainerKind::Object => pipewireao_rtc_spa_json_object(
                    document.as_ptr().cast(),
                    text.as_ptr().cast(),
                    text.len(),
                    &mut error,
                ),
                ContainerKind::Array => pipewireao_rtc_spa_json_array(
                    document.as_ptr().cast(),
                    text.as_ptr().cast(),
                    text.len(),
                    &mut error,
                ),
            }
        };
        Self::from_raw(raw, document, error)
    }

    fn from_raw(
        raw: *mut RawCursor,
        document: &'document str,
        error: RawError,
    ) -> Result<Self, SyntaxError> {
        NonNull::new(raw)
            .map(|raw| Self {
                raw,
                document,
                _not_send_or_sync: PhantomData,
            })
            .ok_or_else(|| decode_error(error))
    }

    pub(crate) fn next(&mut self) -> Result<Option<Token<'document>>, SyntaxError> {
        let mut raw_token = RawToken {
            data: std::ptr::null(),
            size: 0,
            kind: 0,
        };
        let mut error = empty_error();
        // SAFETY: raw is a uniquely owned live cursor. Both output structures
        // are initialized and writable for the duration of the call.
        let status = unsafe {
            pipewireao_rtc_spa_json_array_next(self.raw.as_ptr(), &mut raw_token, &mut error)
        };
        if status < 0 {
            return Err(decode_error(error));
        }
        if status == 0 {
            return Ok(None);
        }
        self.token(raw_token).map(Some)
    }

    pub(crate) fn next_entry(&mut self) -> Result<Option<Entry<'document>>, SyntaxError> {
        let mut raw_entry = RawEntry {
            key: std::ptr::null(),
            key_size: 0,
            value: RawToken {
                data: std::ptr::null(),
                size: 0,
                kind: 0,
            },
        };
        let mut error = empty_error();
        // SAFETY: raw is a uniquely owned live object cursor and both outputs
        // are initialized. The key is copied before the cursor can reuse its
        // internal key buffer.
        let status = unsafe {
            pipewireao_rtc_spa_json_object_next(self.raw.as_ptr(), &mut raw_entry, &mut error)
        };
        if status < 0 {
            return Err(decode_error(error));
        }
        if status == 0 {
            return Ok(None);
        }
        if raw_entry.key.is_null() {
            return Err(invalid_span_error("PipeWire returned a null object key"));
        }
        // SAFETY: The shim owns a key buffer of at least key_size bytes and
        // keeps it live until the next call or cursor destruction.
        let key_bytes =
            unsafe { std::slice::from_raw_parts(raw_entry.key.cast::<u8>(), raw_entry.key_size) };
        let key = std::str::from_utf8(key_bytes)
            .map_err(|_| invalid_span_error("PipeWire returned an object key that is not UTF-8"))?
            .to_owned();
        Ok(Some(Entry {
            key,
            value: self.token(raw_entry.value)?,
        }))
    }

    fn token(&self, raw_token: RawToken) -> Result<Token<'document>, SyntaxError> {
        let document_start = self.document.as_ptr() as usize;
        let document_end = document_start
            .checked_add(self.document.len())
            .ok_or_else(|| invalid_span_error("PipeWire document span overflowed"))?;
        let token_start = raw_token.data as usize;
        let token_end = token_start
            .checked_add(raw_token.size)
            .ok_or_else(|| invalid_span_error("PipeWire token span overflowed"))?;
        if token_start < document_start || token_end > document_end {
            return Err(invalid_span_error(
                "PipeWire returned a token outside the configuration document",
            ));
        }
        // SAFETY: The range check above proves that the SPA-returned token is
        // within the original immutable UTF-8 document. SPA token boundaries
        // cannot split a UTF-8 sequence because the tokenizer validates it.
        let bytes = unsafe { std::slice::from_raw_parts(raw_token.data.cast(), raw_token.size) };
        let text = std::str::from_utf8(bytes)
            .map_err(|_| invalid_span_error("PipeWire returned a token that is not valid UTF-8"))?;
        let kind = match raw_token.kind {
            SCALAR => TokenKind::Scalar,
            OBJECT => TokenKind::Object,
            ARRAY => TokenKind::Array,
            _ => {
                return Err(invalid_span_error(
                    "PipeWire returned an unknown token kind",
                ))
            }
        };
        Ok(Token {
            document: self.document,
            text,
            kind,
        })
    }
}

impl Drop for Cursor<'_> {
    fn drop(&mut self) {
        // SAFETY: raw came from one successful cursor constructor and Cursor
        // is neither Clone nor Copy, so this destroys the allocation once.
        unsafe { pipewireao_rtc_spa_json_cursor_destroy(self.raw.as_ptr()) };
    }
}

fn empty_error() -> RawError {
    RawError {
        line: 0,
        column: 0,
        reason: std::ptr::null(),
    }
}

fn decode_error(error: RawError) -> SyntaxError {
    let reason = if error.reason.is_null() {
        "PipeWire rejected the relaxed SPA-JSON input".to_owned()
    } else {
        // SAFETY: The shim returns only static SPA error strings or static
        // fallback literals and this call copies the value immediately.
        unsafe { CStr::from_ptr(error.reason) }
            .to_string_lossy()
            .into_owned()
    };
    SyntaxError {
        line: error.line,
        column: error.column,
        reason,
    }
}

fn type_error(token: Token<'_>, expected: &str) -> SyntaxError {
    let offset = token.text.as_ptr() as usize - token.document.as_ptr() as usize;
    let (line, column) = line_and_column(token.document, offset);
    SyntaxError {
        line,
        column,
        reason: format!("expected {expected}"),
    }
}

fn line_and_column(document: &str, offset: usize) -> (c_int, c_int) {
    let prefix = &document.as_bytes()[..offset.min(document.len())];
    let (mut line, mut column) = (1_usize, 1_usize);
    for value in prefix {
        if *value == b'\n' {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    (
        c_int::try_from(line).unwrap_or(c_int::MAX),
        c_int::try_from(column).unwrap_or(c_int::MAX),
    )
}

fn invalid_span_error(reason: &str) -> SyntaxError {
    SyntaxError {
        line: 0,
        column: 0,
        reason: reason.to_owned(),
    }
}
