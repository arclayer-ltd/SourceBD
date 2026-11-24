"""A run that read nothing, far less than last time, or failed to save is a
failed run, not a success (#654).

What a person sees is the run's status: the Sources page, the public status
page and the daily digest take a source's "last read" date only from runs
closed as 'success' (etl_source_freshness, 0123), and the queue retries and
alerts only when a run raises. So these tests drive real runs of both engines
through their real `_close_run` and read the status it writes.
"""
from __future__ import annotations

import asyncio
from typing import Any

import pytest

from etl.core import sanctions, scraper
from etl.core.breaker import read_shortfall
from etl.core.sanctions import BaseSanctionScraper, SanctionEntry
from etl.core.scraper import BaseScraper, IncompleteRead, ScrapedRecord


class _Cur:
    """Answers the run log's statements; the last complete read is `last`, and
    `news` is what the sanctions review queue gained during the run."""

    def __init__(self, last: int | None, news: dict[str, int] | None = None) -> None:
        self.last = last
        self.news = news or {}
        self.closed_as: list[str] = []
        self._sql = ""

    def __enter__(self) -> "_Cur":
        return self

    def __exit__(self, *a: Any) -> bool:
        return False

    def execute(self, sql: str, params: Any = None) -> None:
        self._sql = " ".join(sql.split())
        if self._sql.startswith("update public.etl_runs set finished_at = now(), status = %s"):
            self.closed_as.append(params[0])

    def fetchone(self) -> dict[str, Any] | None:
        if "returning id" in self._sql:
            return {"id": "11111111-1111-1111-1111-111111111111"}
        if self._sql.startswith("select records_seen from public.etl_runs"):
            return None if self.last is None else {"records_seen": self.last}
        if "from public.verification_queue q" in self._sql:
            return self.news
        return {}

    def fetchall(self) -> list[dict[str, Any]]:
        return []


class _Db:
    def __init__(self, cur: _Cur) -> None:
        self.cur = cur

    def conn(self) -> "_Db":
        return self

    def cursor(self) -> _Cur:
        return self.cur

    def commit(self) -> None: ...

    def rollback(self) -> None: ...

    def __enter__(self) -> "_Db":
        return self

    def __exit__(self, *a: Any) -> bool:
        return False


@pytest.fixture
def run_log(monkeypatch: pytest.MonkeyPatch):
    def make(last: int | None, news: dict[str, int] | None = None) -> _Cur:
        cur = _Cur(last, news)
        for mod in (scraper, sanctions):
            monkeypatch.setattr(mod, "db", _Db(cur))
            monkeypatch.setattr(mod, "get_source_id", lambda code: "src")
        monkeypatch.setattr("etl.evidence.writer.reset_document_cache", lambda: None)
        return cur
    return make


# --- supplier sources ---------------------------------------------------------

class _Source(BaseScraper):
    code = "bgmea_web"
    source_code = "BGMEA"

    def __init__(self, n: int) -> None:
        super().__init__()
        self.n = n

    async def fetch(self):
        for i in range(self.n):
            yield ScrapedRecord(source_code="BGMEA", source_ref=str(i), company_name=f"Mill {i} Ltd")

    async def gated(self):  # the C4 gate is tested elsewhere; read straight through
        async for rec in self.fetch():
            yield rec


def _run_source(monkeypatch, src: BaseScraper, save) -> None:
    monkeypatch.setattr("etl.core.upsert.upsert_supplier_with_source", save)
    asyncio.run(src.run())


def test_a_source_that_returns_an_empty_page_fails(run_log, monkeypatch) -> None:
    log = run_log(last=4307)
    with pytest.raises(IncompleteRead, match="read no records"):
        _run_source(monkeypatch, _Source(0), lambda rec: None)
    assert log.closed_as == ["failed"]


def test_a_source_whose_saves_raise_fails(run_log, monkeypatch) -> None:
    log = run_log(last=3)

    def save(rec):
        raise RuntimeError("connection reset")

    with pytest.raises(IncompleteRead, match="3 of 3 records failed to save"):
        _run_source(monkeypatch, _Source(3), save)
    assert log.closed_as == ["failed"]


def test_one_failed_save_among_good_ones_fails(run_log, monkeypatch) -> None:
    log = run_log(last=3)
    outcomes = iter([None, RuntimeError("bad row"), "sup-1"])

    def save(rec):
        out = next(outcomes)
        if isinstance(out, Exception):
            raise out
        return out

    with pytest.raises(IncompleteRead, match="1 of 3"):
        _run_source(monkeypatch, _Source(3), save)
    assert log.closed_as == ["failed"]


def test_far_fewer_records_than_last_time_fails(run_log, monkeypatch) -> None:
    log = run_log(last=4307)
    with pytest.raises(IncompleteRead, match="read 300 records against 4307"):
        _run_source(monkeypatch, _Source(300), lambda rec: None)
    assert log.closed_as == ["failed"]


def test_accept_changes_releases_a_genuinely_smaller_source(run_log, monkeypatch) -> None:
    log = run_log(last=4307)
    src = _Source(300)
    src.accept_changes = True
    _run_source(monkeypatch, src, lambda rec: None)
    assert log.closed_as == ["success"]


def test_an_ordinary_read_still_succeeds(run_log, monkeypatch) -> None:
    log = run_log(last=4315)
    _run_source(monkeypatch, _Source(4301), lambda rec: None)
    assert log.closed_as == ["success"]


def test_a_first_read_has_nothing_to_compare_against(run_log, monkeypatch) -> None:
    log = run_log(last=None)
    _run_source(monkeypatch, _Source(5), lambda rec: None)
    assert log.closed_as == ["success"]


def test_a_gated_pass_may_read_nothing(run_log, monkeypatch) -> None:
    log = run_log(last=590)
    src = _Source(0)
    src.whole_read = False  # bkmea_detail: only members whose list row moved
    _run_source(monkeypatch, src, lambda rec: None)
    assert log.closed_as == ["success"]


def test_failed_saves_are_counted_afresh_each_run(run_log, monkeypatch) -> None:
    run_log(last=2)
    src = _Source(2)

    def save(rec):
        raise RuntimeError("down")

    with pytest.raises(IncompleteRead):
        _run_source(monkeypatch, src, save)
    log = run_log(last=2)
    _run_source(monkeypatch, src, lambda rec: None)
    assert log.closed_as == ["success"]


def test_the_gated_sources_say_so() -> None:
    from etl.scrapers.registry import SCRAPERS

    partial = {code for code, cls in SCRAPERS.items() if not cls.whole_read}
    assert partial == {"bkmea_detail", "rsc_documents"}


# --- sanctions lists ------------------------------------------------------------

class _List(BaseSanctionScraper):
    code = "uk_ofsi"
    source_code = "UK_OFSI"

    def __init__(self, n: int) -> None:
        super().__init__()
        self.n = n

    async def fetch(self):  # type: ignore[override]
        for i in range(self.n):
            yield SanctionEntry(list_code="uk_ofsi", source_code="UK_OFSI",
                                entry_ref=str(i), entity_name=f"Entity {i}")


def _run_list(monkeypatch, lst: BaseSanctionScraper, ingest) -> None:
    monkeypatch.setattr(sanctions, "ingest_sanction_entry", ingest)
    asyncio.run(lst.run())


def _ingested(entry, run_id=None):
    return {"entry_id": entry.entry_ref, "matched_supplier_ids": [], "screened": 0}


def test_a_sanctions_list_that_reads_nothing_fails(run_log, monkeypatch) -> None:
    log = run_log(last=1286)
    with pytest.raises(IncompleteRead, match="read no records"):
        _run_list(monkeypatch, _List(0), _ingested)
    assert log.closed_as == ["failed"]


def test_a_sanctions_list_whose_saves_raise_fails(run_log, monkeypatch) -> None:
    log = run_log(last=2)

    def ingest(entry, run_id=None):
        raise RuntimeError("deadlock detected")

    with pytest.raises(IncompleteRead, match="2 of 2 records failed to save"):
        _run_list(monkeypatch, _List(2), ingest)
    assert log.closed_as == ["failed"]


def test_a_sanctions_list_far_shorter_than_last_time_fails(run_log, monkeypatch) -> None:
    log = run_log(last=1286)
    with pytest.raises(IncompleteRead):
        _run_list(monkeypatch, _List(40), _ingested)
    assert log.closed_as == ["failed"]


def test_a_full_sanctions_read_still_succeeds(run_log, monkeypatch) -> None:
    log = run_log(last=10)
    _run_list(monkeypatch, _List(10), _ingested)
    assert log.closed_as == ["success"]


def test_a_failed_sanctions_read_still_tells_of_the_matches_it_stored(run_log, monkeypatch) -> None:
    # Two entries matched a supplier (stored, supplier hidden from search) and a
    # third failed to save. The run must fail, and the matches must still be
    # told: the retry sees those two entries as unchanged and never screens them
    # again, so this is the only notice they get.
    log = run_log(last=3, news={"hits": 2, "cleared": 0})
    sent: list[str] = []
    monkeypatch.setattr("etl.core.notify.slack", sent.append)
    outcomes = iter([None, None, RuntimeError("deadlock detected")])

    def ingest(entry, run_id=None):
        out = next(outcomes)
        if isinstance(out, Exception):
            raise out
        return {"entry_id": entry.entry_ref, "matched_supplier_ids": ["sup"], "screened": 1}

    with pytest.raises(IncompleteRead, match="1 of 3"):
        _run_list(monkeypatch, _List(3), ingest)
    assert log.closed_as == ["failed"]
    assert len(sent) == 1
    assert "2 possible new matches" in sent[0]
    assert "failed" in sent[0]


def test_a_sanctions_run_with_nothing_new_sends_no_notice(run_log, monkeypatch) -> None:
    run_log(last=2)
    sent: list[str] = []
    monkeypatch.setattr("etl.core.notify.slack", sent.append)

    def ingest(entry, run_id=None):
        raise RuntimeError("down")

    with pytest.raises(IncompleteRead):
        _run_list(monkeypatch, _List(2), ingest)
    assert sent == []


# --- the decision ------------------------------------------------------------

def test_shortfall_rule() -> None:
    def f(**kw: Any) -> str | None:
        base = {"seen": 100, "failed_saves": 0, "last_complete": 100, "whole_read": True}
        return read_shortfall(**{**base, **kw})

    assert f() is None
    assert f(seen=90) is None
    assert f(seen=89) is not None
    assert f(seen=89, accept=True) is None
    assert f(seen=0, accept=True) is not None, "accepting a smaller read never accepts an empty one"
    assert f(failed_saves=1, accept=True) is not None, "a failed save is never accepted"
    assert f(failed_saves=1, whole_read=False) is not None
    assert f(seen=0, whole_read=False) is None
    assert f(last_complete=None, seen=1) is None
