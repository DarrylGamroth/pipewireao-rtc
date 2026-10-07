//! Decode a fixed negotiated Format using the public SPA POD byte layout.

use pipewire as pw;
use pw::spa::pod::deserialize::PodDeserializer;
use pw::spa::pod::{Object, Value};
use pw::spa::utils::SpaTypes;

const MAX_FORMAT_BYTES: usize = 64 * 1024;

pub(super) fn decode(bytes: &[u8]) -> Result<Object, String> {
    let normalized = normalize(bytes)?;
    let (remaining, value) = PodDeserializer::deserialize_any_from(&normalized)
        .map_err(|error| format!("cannot decode negotiated Format: {error:?}"))?;
    if !remaining.is_empty() {
        return Err("trailing bytes after negotiated Format".into());
    }
    match value {
        Value::Object(object) => Ok(object),
        _ => Err("negotiated Format is not an object".into()),
    }
}

fn word(bytes: &[u8], offset: usize) -> Result<u32, String> {
    let value = bytes
        .get(offset..offset + 4)
        .ok_or("truncated Format POD field")?;
    Ok(u32::from_ne_bytes(
        value.try_into().expect("four-byte field"),
    ))
}

fn aligned(size: usize) -> Result<usize, String> {
    size.checked_add(7)
        .map(|size| size & !7)
        .ok_or_else(|| "Format size overflow".into())
}

fn pod_end(bytes: &[u8], start: usize, limit: usize) -> Result<usize, String> {
    let body_size = usize::try_from(word(bytes, start)?).map_err(|_| "invalid POD size")?;
    let end = start
        .checked_add(8)
        .and_then(|start| start.checked_add(body_size))
        .ok_or("Format POD size overflow")?;
    if end > limit {
        return Err("truncated Format POD".into());
    }
    Ok(end)
}

fn scalar_width(kind: u32) -> Option<usize> {
    match kind {
        pw::spa::sys::SPA_TYPE_None => Some(0),
        pw::spa::sys::SPA_TYPE_Bool
        | pw::spa::sys::SPA_TYPE_Id
        | pw::spa::sys::SPA_TYPE_Int
        | pw::spa::sys::SPA_TYPE_Float => Some(4),
        pw::spa::sys::SPA_TYPE_Long
        | pw::spa::sys::SPA_TYPE_Double
        | pw::spa::sys::SPA_TYPE_Rectangle
        | pw::spa::sys::SPA_TYPE_Fraction
        | pw::spa::sys::SPA_TYPE_Fd => Some(8),
        _ => None,
    }
}

fn check_value(value: &[u8]) -> Result<(), String> {
    let kind = word(value, 4)?;
    let body = value.get(8..).ok_or("truncated Format value")?;
    if let Some(width) = scalar_width(kind) {
        return if body.len() == width {
            Ok(())
        } else {
            Err("invalid Format scalar width".into())
        };
    }
    match kind {
        pw::spa::sys::SPA_TYPE_String => {
            let Some((&0, text)) = body.split_last() else {
                return Err("Format String has no terminator".into());
            };
            if text.contains(&0) || std::str::from_utf8(text).is_err() {
                return Err("invalid Format String".into());
            }
            Ok(())
        }
        pw::spa::sys::SPA_TYPE_Bytes => Ok(()),
        pw::spa::sys::SPA_TYPE_Array => {
            let width = usize::try_from(word(body, 0)?).map_err(|_| "invalid Array child size")?;
            let child_kind = word(body, 4)?;
            if width == 0 || scalar_width(child_kind) != Some(width) {
                return Err("unsupported Format Array child".into());
            }
            if (body.len() - 8) % width != 0 {
                return Err("partial Format Array element".into());
            }
            Ok(())
        }
        _ => Err("unsupported fixed Format value".into()),
    }
}

fn fixed_value(value: &[u8]) -> Result<&[u8], String> {
    let child = if word(value, 4)? == pw::spa::sys::SPA_TYPE_Choice {
        // Public spa_pod_choice: POD header, kind/flags, child header, values.
        if value.len() < 24
            || word(value, 8)? != pw::spa::sys::SPA_CHOICE_None
            || word(value, 12)? != 0
        {
            return Err("negotiated Format Choice is not fixed".into());
        }
        let child = &value[16..];
        if pod_end(child, 0, child.len())? != child.len() || word(child, 0)? == 0 {
            return Err("fixed Format Choice must contain exactly one complete child".into());
        }
        child
    } else {
        value
    };
    check_value(child)?;
    Ok(child)
}

fn normalize(bytes: &[u8]) -> Result<Vec<u8>, String> {
    if bytes.len() > MAX_FORMAT_BYTES || bytes.len() < 16 {
        return Err("negotiated Format is truncated or exceeds 64 KiB".into());
    }
    let end = pod_end(bytes, 0, bytes.len())?;
    if end != bytes.len()
        || word(bytes, 4)? != pw::spa::sys::SPA_TYPE_Object
        || word(bytes, 8)? != SpaTypes::ObjectParamFormat.as_raw()
        || word(bytes, 12)? != pw::spa::param::ParamType::Format.as_raw()
    {
        return Err("expected one complete native Format object".into());
    }
    let mut normalized = Vec::with_capacity(bytes.len());
    normalized.extend_from_slice(&bytes[..16]);
    let mut offset = 16;
    while offset < end {
        let value_start = offset
            .checked_add(8)
            .ok_or("Format property size overflow")?;
        let value_end = pod_end(bytes, value_start, end)?;
        let next = aligned(value_end)?;
        if next > end {
            return Err("truncated Format property padding".into());
        }
        normalized.extend_from_slice(&bytes[offset..value_start]);
        normalized.extend_from_slice(fixed_value(&bytes[value_start..value_end])?);
        normalized.resize(aligned(normalized.len())?, 0);
        offset = next;
    }
    let size = u32::try_from(normalized.len() - 8).map_err(|_| "Format size overflow")?;
    normalized[..4].copy_from_slice(&size.to_ne_bytes());
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pw::spa::param::format::{ElementType, NdArrayFormat, NdArrayLayout};
    use pw::spa::pod::serialize::PodSerializer;
    use pw::spa::pod::{Property, PropertyFlags};
    use pw::spa::utils::{Fraction, SpaTypes};
    use std::io::Cursor;

    fn expected() -> Object {
        let format = NdArrayFormat::new(
            ElementType::F32Le,
            vec![2, 3],
            NdArrayLayout::RowMajor,
            Some(Fraction { num: 100, denom: 1 }),
        )
        .unwrap();
        let mut properties = format.properties();
        properties[0].flags = PropertyFlags::MANDATORY;
        properties.push(Property::new(
            pw::spa::sys::SPA_FORMAT_NDARRAY_schema,
            Value::String("org.pipewireao.test.fixed/1".into()),
        ));
        Object {
            type_: SpaTypes::ObjectParamFormat.as_raw(),
            id: pw::spa::param::ParamType::Format.as_raw(),
            properties,
        }
    }

    fn serialized(value: &Value) -> Vec<u8> {
        PodSerializer::serialize(Cursor::new(Vec::new()), value)
            .unwrap()
            .0
            .into_inner()
    }

    fn fixed_choices(object: &Object) -> (Vec<u8>, Vec<usize>) {
        let mut bytes = vec![0; 8];
        bytes[4..8].copy_from_slice(&pw::spa::sys::SPA_TYPE_Object.to_ne_bytes());
        bytes.extend_from_slice(&object.type_.to_ne_bytes());
        bytes.extend_from_slice(&object.id.to_ne_bytes());
        let mut offsets = Vec::new();
        for property in &object.properties {
            bytes.extend_from_slice(&property.key.to_ne_bytes());
            bytes.extend_from_slice(&property.flags.bits().to_ne_bytes());
            offsets.push(bytes.len());
            let value = serialized(&property.value);
            let child_size = u32::from_ne_bytes(value[..4].try_into().unwrap());
            bytes.extend_from_slice(&(16 + child_size).to_ne_bytes());
            bytes.extend_from_slice(&pw::spa::sys::SPA_TYPE_Choice.to_ne_bytes());
            bytes.extend_from_slice(&pw::spa::sys::SPA_CHOICE_None.to_ne_bytes());
            bytes.extend_from_slice(&0_u32.to_ne_bytes());
            bytes.extend_from_slice(&value[..8 + usize::try_from(child_size).unwrap()]);
            bytes.resize((bytes.len() + 7) & !7, 0);
        }
        let body_size = u32::try_from(bytes.len() - 8).unwrap();
        bytes[..4].copy_from_slice(&body_size.to_ne_bytes());
        (bytes, offsets)
    }

    #[test]
    fn fixed_choices_preserve_scalar_array_string_and_property_flags() {
        let expected = expected();
        let (bytes, _) = fixed_choices(&expected);
        assert_eq!(decode(&bytes).unwrap(), expected);
        let format =
            NdArrayFormat::<Vec<u32>>::from_properties(&decode(&bytes).unwrap().properties)
                .unwrap();
        assert_eq!(format.shape(), &[2, 3]);
        assert_eq!(format.rate(), Some(Fraction { num: 100, denom: 1 }));
        assert_eq!(
            decode(&serialized(&Value::Object(expected.clone()))).unwrap(),
            expected
        );
    }

    #[test]
    fn nonfixed_choices_extra_values_and_partial_children_are_rejected() {
        let (bytes, offsets) = fixed_choices(&expected());
        for kind in [
            pw::spa::sys::SPA_CHOICE_Range,
            pw::spa::sys::SPA_CHOICE_Step,
            pw::spa::sys::SPA_CHOICE_Enum,
            pw::spa::sys::SPA_CHOICE_Flags,
        ] {
            let mut nonfixed = bytes.clone();
            nonfixed[offsets[0] + 8..offsets[0] + 12].copy_from_slice(&kind.to_ne_bytes());
            assert!(decode(&nonfixed).is_err());
        }
        let mut extra_value = bytes.clone();
        // The first Id child has four padding bytes after its sole value.
        // Claiming those bytes as a second value must fail exact arity.
        extra_value[offsets[0]..offsets[0] + 4].copy_from_slice(&24_u32.to_ne_bytes());
        assert!(decode(&extra_value).is_err());
        for child_size in [0_u32, 3, 5] {
            let mut malformed = bytes.clone();
            malformed[offsets[0] + 16..offsets[0] + 20].copy_from_slice(&child_size.to_ne_bytes());
            assert!(decode(&malformed).is_err());
        }
        let mut flagged = bytes.clone();
        flagged[offsets[0] + 12..offsets[0] + 16].copy_from_slice(&1_u32.to_ne_bytes());
        assert!(decode(&flagged).is_err());
    }

    #[test]
    fn array_child_width_string_termination_and_object_extent_are_checked() {
        let (bytes, offsets) = fixed_choices(&expected());
        let mut bad_array = bytes.clone();
        bad_array[offsets[3] + 24..offsets[3] + 28].copy_from_slice(&0_u32.to_ne_bytes());
        assert!(decode(&bad_array).is_err());
        let mut bad_string = bytes.clone();
        let string = *offsets.last().unwrap();
        let string_size = usize::try_from(word(&bytes, string + 16).unwrap()).unwrap();
        bad_string[string + 24 + string_size - 1] = b'x';
        assert!(decode(&bad_string).is_err());
        for end in 0..bytes.len() {
            assert!(decode(&bytes[..end]).is_err());
        }
        let mut extra = bytes.clone();
        extra.extend_from_slice(&[0; 8]);
        assert!(decode(&extra).is_err());
        let mut enum_format = bytes;
        enum_format[12..16]
            .copy_from_slice(&pw::spa::param::ParamType::EnumFormat.as_raw().to_ne_bytes());
        assert!(decode(&enum_format).is_err());
    }
}
