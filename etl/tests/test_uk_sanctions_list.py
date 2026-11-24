"""UK sanctions: the reader takes the UK Sanctions List, and refuses a file it cannot read (#660).

The UK retired OFSI's consolidated list in January 2026. Production read the same 1,286 entities
from it in May, June and October 2026, the newest listed 19 December 2025, so a company the UK
designated this year carried no warning. The failure to guard against is silence: a file that
parses to nothing reports success and every supplier screens clean.
"""
from __future__ import annotations

import asyncio
from datetime import date
from pathlib import Path

import pytest

from etl.scrapers import uk_ofsi
from etl.scrapers.uk_ofsi import UkOfsiScraper, parse_designations

SAMPLE = (Path(__file__).parent / "fixtures" / "uk_sanctions_list" / "sample.xml").read_bytes()

# The retired list's layout, for the refusal test.
OLD_CONLIST = b"""<?xml version="1.0" encoding="utf-8"?>
<ArrayOfFinancialSanctionsTarget xmlns="http://schemas.hmtreasury.gov.uk/ofsi/consolidatedlist">
  <FinancialSanctionsTarget>
    <Name6>EXAMPLE TEXTILE TRADING LLC</Name6><GroupTypeDescription>Entity</GroupTypeDescription>
    <GroupID>99001</GroupID><AliasType>Primary name</AliasType>
  </FinancialSanctionsTarget>
</ArrayOfFinancialSanctionsTarget>"""


class _Status:
    value = "ok"


class _Doc:
    ok = True
    citable_url = uk_ofsi.URL
    fetch_status = _Status()
    error_message = None

    def __init__(self, body: bytes) -> None:
        self.body_bytes = body


def _read(monkeypatch, body: bytes, floor: int = 1) -> list:
    requested: list[str] = []

    async def fake_acquire(self, req):
        requested.append(req.url)
        return _Doc(body)

    monkeypatch.setattr(UkOfsiScraper, "acquire", fake_acquire)
    scraper = UkOfsiScraper.__new__(UkOfsiScraper)
    scraper.min_entities = floor  # the sample holds two entities

    async def run():
        return [e async for e in scraper.fetch()]

    entries = asyncio.run(run())
    assert requested == ["https://sanctionslist.fcdo.gov.uk/docs/UK-Sanctions-List.xml"]
    return entries


def test_the_reader_takes_the_uk_sanctions_list(monkeypatch):
    entries = _read(monkeypatch, SAMPLE)

    assert [e.entity_name for e in entries] == ["EXAMPLE TEXTILE TRADING LLC", "SECOND EXAMPLE COMPANY"]
    first, second = entries
    # The old list's reference, so a company on both lists stays one row and keeps its matches.
    assert first.entry_ref == "ofsi-99001"
    assert first.aliases == ["EXAMPLE TEXTILES"]
    assert first.country == "Testland"
    assert first.listed_date == date(2026, 2, 10)
    assert first.status == "Asset freeze|Trust services sanctions"
    assert first.status_notes == "Involved in a test of the reader."
    assert first.raw["unique_id"] == "TST0001"
    assert first.source_url == "https://sanctionslist.fcdo.gov.uk/docs/UK-Sanctions-List.xml"
    assert "<UniqueID>TST0001</UniqueID>" in first.evidence.document_text
    # A designation with no OFSI group id is keyed by the list's own reference.
    assert second.entry_ref == "uksl-TST0002"
    assert second.country is None


def test_individuals_and_ships_are_not_read():
    names = [d["entity_name"] for d in parse_designations(SAMPLE, min_entities=1)]
    assert "EXAMPLE PERSON" not in names and "EXAMPLE VESSEL" not in names


def test_tags_are_read_whatever_their_case_or_namespace():
    xml = SAMPLE.replace(b"UKStatementofReasons", b"UKStatementOfReasons").replace(
        b"<Designations ", b'<Designations xmlns="urn:example" '
    )
    first = parse_designations(xml, min_entities=1)[0]
    assert first["reasons"] == "Involved in a test of the reader."
    assert first["entity_name"] == "EXAMPLE TEXTILE TRADING LLC"


def test_the_retired_list_is_refused_not_read_as_empty(monkeypatch):
    with pytest.raises(RuntimeError, match="Refusing to report an empty sanctions list"):
        _read(monkeypatch, OLD_CONLIST)


def test_a_list_far_shorter_than_any_real_edition_is_refused():
    """Two entities is a layout the reader no longer understands, not the UK's list."""
    with pytest.raises(RuntimeError, match="Refusing to report a short sanctions list"):
        parse_designations(SAMPLE)
