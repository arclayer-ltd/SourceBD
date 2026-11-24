"""UK Sanctions List scraper (Tier 5 regulatory).

Source: the UK Sanctions List, published by the Foreign, Commonwealth and Development Office.
  https://sanctionslist.fcdo.gov.uk/docs/UK-Sanctions-List.xml
  (landing page: https://www.gov.uk/government/publications/the-uk-sanctions-list)

Since January 2026 this is the UK's one official list of designations, and OFSI's Consolidated
List of Asset Freeze Targets (`ConList.xml`, which this module read before) is no longer updated:
production read exactly 1,286 entities from it in May, June and October 2026, the newest listed
19 December 2025 (#660). The code stays `uk_ofsi`: it is a database enum value and the key of every
stored entry, timer and screening match, and changing it would orphan them.

Layout (one <Designation> per designated person, entity or ship, under <Designations>):
  UniqueID                  the list's own reference, e.g. RUS0270
  OFSIGroupID               OFSI's group id: the same number the old ConList used as GroupID
  IndividualEntityShip      'Individual' | 'Entity' | 'Ship'
  Names/Name                Name1..Name6 and NameType ('Primary Name' | 'Alias')
  RegimeName, DateDesignated, LastUpdated, SanctionsImposed, UKStatementofReasons
  Addresses/Address         AddressLine1..6 and AddressCountry

Tags are matched by local name and without regard to case, so a namespace or a change such as
`UKStatementOfReasons` for `UKStatementofReasons` does not lose a field.

An entry keeps the old list's reference, `ofsi-<OFSIGroupID>`, so a company on both lists stays the
same row and its screening matches carry over; one with no OFSI group id is `uksl-<UniqueID>`.

We screen entities only. Individuals and ships are dropped (as in `ofac_sdn`): a Bangladesh garment
factory cannot be a sanctioned person or vessel, and keeping them only invites false matches.

The reader refuses, rather than returning a short list, when the file is not this layout or holds
fewer entities than any real edition: a read of nothing would otherwise report success and every
supplier would screen clean.
"""
from __future__ import annotations

import io
import re
from datetime import date, datetime
from typing import Any, AsyncIterator

from lxml import etree

from etl.acquire import AcquireRequest
from etl.core.acquiring import AcquiringSanctionScraper
from etl.core.sanctions import SanctionEntry
from etl.core.scraper import EvidenceAttachment

URL = "https://sanctionslist.fcdo.gov.uk/docs/UK-Sanctions-List.xml"

# The retired OFSI list held 1,286 entities; the UK Sanctions List carries every one of those
# designations and more. Fewer than this means the file was not read as it is laid out.
MIN_ENTITIES = 500


def _local(tag: Any) -> str:
    if not isinstance(tag, str):  # comments, processing instructions
        return ""
    return tag.rsplit("}", 1)[-1].lower()


def _children(elem, name: str) -> list:
    name = name.lower()
    return [c for c in elem if _local(c.tag) == name]


def _txt(elem, name: str) -> str:
    for child in _children(elem, name):
        if child.text and child.text.strip():
            return child.text.strip()
    return ""


def _parse_date(s: str) -> date | None:
    s = s.strip()
    for pattern, fmt in ((r"\d{4}-\d{2}-\d{2}", "%Y-%m-%d"), (r"\d{2}/\d{2}/\d{4}", "%d/%m/%Y")):
        m = re.match(pattern, s)
        if m:
            try:
                return datetime.strptime(m.group(0), fmt).date()
            except ValueError:
                return None
    return None


def _name(name_elem) -> str:
    parts = [_txt(name_elem, f"Name{i}") for i in range(1, 7)]
    return " ".join(p for p in parts if p)


def _country(designation) -> str:
    for addresses in _children(designation, "Addresses"):
        for address in _children(addresses, "Address"):
            country = _txt(address, "AddressCountry") or _txt(address, "Country")
            if country:
                return country
    return ""


def _xpath(unique_id: str, field: str | None = None) -> str:
    """Locator into the list: the designation, optionally a field within it."""
    base = f"xml:Designation[UniqueID={unique_id}]"
    return f"{base}/{field}" if field else base


def parse_designations(xml_bytes: bytes, min_entities: int = MIN_ENTITIES) -> list[dict[str, Any]]:
    """Every entity designation in the file, one dict each. Raises if the file is not the list."""
    designations = 0
    out: list[dict[str, Any]] = []
    parser = etree.iterparse(io.BytesIO(xml_bytes), events=("end",))
    for _event, elem in parser:
        if _local(elem.tag) != "designation":
            continue
        designations += 1
        try:
            if _txt(elem, "IndividualEntityShip").lower() != "entity":
                continue
            unique_id = _txt(elem, "UniqueID")
            group_id = _txt(elem, "OFSIGroupID")
            if not unique_id and not group_id:
                continue

            primary = ""
            others: list[str] = []
            for names in _children(elem, "Names"):
                for n in _children(names, "Name"):
                    full = _name(n)
                    if not full:
                        continue
                    if not primary and _txt(n, "NameType").lower().startswith("primary"):
                        primary = full
                    else:
                        others.append(full)
            if not primary and others:
                primary = others.pop(0)
            if not primary:
                continue
            aliases: list[str] = []
            for a in others:
                if a != primary and a not in aliases:
                    aliases.append(a)

            out.append({
                "entry_ref": f"ofsi-{group_id}" if group_id else f"uksl-{unique_id}",
                "unique_id": unique_id or group_id,
                "group_id": group_id or None,
                "entity_name": primary,
                "aliases": aliases,
                "country": _country(elem) or None,
                "listed_date": _parse_date(_txt(elem, "DateDesignated")),
                "last_updated": _parse_date(_txt(elem, "LastUpdated")),
                "regime": _txt(elem, "RegimeName"),
                "status": _txt(elem, "SanctionsImposed") or "Designated",
                "reasons": _txt(elem, "UKStatementofReasons")[:2000] or None,
                "source_xml": etree.tostring(elem, encoding="unicode", with_tail=False),
            })
        finally:
            # Free memory while streaming a large document.
            elem.clear()
            while elem.getprevious() is not None:
                del elem.getparent()[0]

    if designations == 0:
        raise RuntimeError(
            "uk_ofsi: the file holds no <Designation> elements, so it is not the UK Sanctions List "
            "as this reader knows it. Refusing to report an empty sanctions list."
        )
    if len(out) < min_entities:
        raise RuntimeError(
            f"uk_ofsi: {designations} designations but only {len(out)} entities read (expected at "
            f"least {min_entities}); the layout has changed. Refusing to report a short sanctions list."
        )
    return out


class UkOfsiScraper(AcquiringSanctionScraper):
    code = "uk_ofsi"
    source_code = "UK_OFSI"
    transport = "direct"
    fallback_transport = None
    rps = 0.5
    min_entities = MIN_ENTITIES

    async def fetch(self) -> AsyncIterator[SanctionEntry]:
        doc = await self.acquire(
            AcquireRequest(url=URL, want_bytes=True, label="UK Sanctions List XML")
        )
        if not doc.ok or not doc.body_bytes:
            raise RuntimeError(
                f"uk_ofsi: {URL} unreadable ({doc.fetch_status.value}: "
                f"{doc.error_message}). Refusing to report an empty sanctions list."
            )

        for d in parse_designations(doc.body_bytes, self.min_entities):
            uid = d["unique_id"]
            yield SanctionEntry(
                list_code="uk_ofsi",
                source_code="UK_OFSI",
                entry_ref=d["entry_ref"],
                entity_name=d["entity_name"],
                aliases=d["aliases"],
                country=d["country"],
                merchandise=None,
                listed_date=d["listed_date"],
                status=d["status"],
                status_notes=d["reasons"],
                source_url=doc.citable_url,
                raw={
                    "unique_id": uid,
                    "group_id": d["group_id"],
                    "regime": d["regime"],
                    "last_updated": d["last_updated"].isoformat() if d["last_updated"] else None,
                },
                evidence=EvidenceAttachment(
                    doc=doc,
                    locators={
                        "entity_name": _xpath(uid, "Names/Name"),
                        "country": _xpath(uid, "Addresses/Address/AddressCountry"),
                        "listed_date": _xpath(uid, "DateDesignated"),
                        "status": _xpath(uid, "SanctionsImposed"),
                        "status_notes": _xpath(uid, "UKStatementofReasons"),
                    },
                    default_locator=_xpath(uid),
                    document_text=d["source_xml"],
                    document_is_html=False,
                    subject_table="sanctions_list_entries",
                ),
            )
