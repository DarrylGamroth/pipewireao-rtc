"""Write a frame range from the benchmark's single-HDU UInt16 FITS cube."""

from __future__ import annotations

from pathlib import Path


BLOCK = 2880
CARD = 80


def _card_value(cards: list[bytes], name: str) -> int:
    matches = [card for card in cards if card[:8].decode("ascii").strip() == name]
    if len(matches) != 1:
        raise ValueError(f"expected one {name} FITS card")
    try:
        return int(matches[0][10:30])
    except ValueError as error:
        raise ValueError(f"invalid {name} FITS card value") from error


def write_fits_segment(source: Path, destination: Path, start: int, count: int) -> None:
    """Write frames ``start:start+count`` from a primary 64x64xN U16 cube.

    The input must contain exactly one 2880-byte header block and the padded
    image payload. ``start`` is zero based. The output is created exclusively.
    """
    if not isinstance(start, int) or isinstance(start, bool) or start < 0:
        raise ValueError("start must be a nonnegative integer")
    if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
        raise ValueError("count must be a positive integer")

    content = source.read_bytes()
    header = content[:BLOCK]
    if len(header) != BLOCK:
        raise ValueError("expected a single 2880-byte primary FITS header")
    cards = [header[index:index + CARD] for index in range(0, BLOCK, CARD)]
    end = next((index for index, card in enumerate(cards)
                if card.startswith(b"END     ")), None)
    if end is None:
        raise ValueError("FITS header has no END card")
    active_cards = cards[:end]
    if _card_value(active_cards, "BITPIX") != 16 or _card_value(active_cards, "NAXIS") != 3:
        raise ValueError("expected a three-axis signed-16 FITS image")
    width = _card_value(active_cards, "NAXIS1")
    height = _card_value(active_cards, "NAXIS2")
    frames = _card_value(active_cards, "NAXIS3")
    if width <= 0 or height <= 0 or frames <= 0:
        raise ValueError("FITS image dimensions must be positive")
    if start >= frames or count > frames - start:
        raise ValueError("requested frame segment is outside the source cube")

    frame_bytes = width * height * 2
    payload_bytes = frame_bytes * frames
    payload = content[BLOCK:BLOCK + payload_bytes]
    padded_payload_bytes = ((payload_bytes + BLOCK - 1) // BLOCK) * BLOCK
    if len(payload) != payload_bytes or len(content) != BLOCK + padded_payload_bytes:
        raise ValueError("source contains another HDU or has an invalid payload size")

    for index, card in enumerate(active_cards):
        if card.startswith(b"NAXIS3  "):
            cards[index] = f"NAXIS3  = {count:20d}".ljust(CARD).encode("ascii")
        elif card.startswith(b"CHECKSUM"):
            cards[index] = b"HISTORY Benchmark segment contains selected source frames".ljust(CARD)
        elif card.startswith(b"DATASUM "):
            cards[index] = b"HISTORY Segment frames are not new AO simulation samples".ljust(CARD)

    first = start * frame_bytes
    selected = payload[first:first + count * frame_bytes]
    padding = b"\0" * (-len(selected) % BLOCK)
    with destination.open("xb") as output:
        output.write(b"".join(cards))
        output.write(selected)
        output.write(padding)
