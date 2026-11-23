# Product

<!-- impeccable:product-schema 1 -->

What SourceBD is and the decisions about it that are in force. This file is the authority on the
product; the code is the authority on how it is built.

## Platform

web

## Users

Sourcing and compliance people at clothing brands and retailers in the UK, US,
EU and Canada. They are at a desk, shortlisting Bangladesh factories and buying
houses, checking each one's registers, certificates and safety record, then
sending an RFQ. Secondary: Bangladeshi suppliers claiming and editing their own
record, and SourceBD admins.

## Product Purpose

Let a buyer find, vet, save and message verified Bangladesh RMG suppliers
without trusting anyone's opinion: every fact on a supplier is a receipt from a
named public source. Success is a buyer who shortlists and sends an RFQ in one
sitting and can show their compliance team where each fact came from.

## Positioning

Receipts, not opinions. Facts come from government registers, industry bodies
(BGMEA, BKMEA, BTMA, BGAPMEA), certification bodies, brand disclosures and
foreign regulators, ranked in that order. SourceBD never scores, grades or rates
a supplier.

## Operating Context

Search with filters, open a supplier record beside the results, save to a list,
send an RFQ to one or up to 50 suppliers, follow replies in Messages, track
orders, watch certificate expiry and sanction flags in the Compliance hub.

## Capabilities and Constraints

- Server enforces auth, role and ownership; hiding UI is never a control.
- Contact details (email, phones, website, contact name and role) are locked
  unless the server returns them. It returns them to buyers on Growth and
  Enterprise and to admins (founder, 12 Oct 2026), as the registers filed them;
  everyone else sees how many are on file. Never for a sanctioned supplier,
  and an account opens at most 200 different suppliers' details in 24 hours
  (a starting value). The locked state is a real state,
  not a blur.
- A sanctioned supplier carries a red warning on every surface, and Send RFQ is
  refused.
- No SourceBD score, grade, rating or star outside admin.
- Every fact has room for its source mark and a link to the source page.
- No new packages. Tailwind utilities, the v4 kit under
  `components/kit` and `components/patterns`, tokens in `lib/design/tokens.ts`.
- Third-party logos follow `context/logos.lock.md`.

## Brand Commitments

Name SourceBD. Brand green is fixed. One type family (Geist). Plain, calm voice:
state the fact and where it came from.

## Evidence on Hand

Live production data: about 10,900 companies, 10,266 published. No testimonials, customer
logos or benchmarks exist; none may be invented.

## Product Principles

1. Every fact shows its source.
2. Nothing fake: real records or nothing.
3. Locked, empty, stale and sanctioned are normal states, designed as such.
4. The buyer never loses their search: records open beside the results.

## Accessibility & Inclusion

WCAG 2.2 AA; contrast pairs are tested in `lib/design/tokens.ts`. Works with
reduced motion and at 320px.

## Source trust order

Higher overrides lower. A fact from a lower tier never replaces one from a higher tier.

1. Government and regulators in Bangladesh (EPB, RSC, RJSC, DIFE, BEPZA).
2. Industry registers (BGMEA, BKMEA, BTMA, BGAPMEA).
3. Certificate bodies (WRAP, OEKO-TEX, GOTS and the like).
4. Brand supplier lists (H&M, ASOS, M&S, Next and the like).
5. Foreign regulators and sanctions lists (UFLPA, US withhold-release orders, OFAC, EU, UK).
6. Everything else: cross-check only. It never creates a supplier and never stands alone.

A supplier is published only with at least one record from tiers 1 to 3 behind it.

## Decisions in force

- The product is free while in beta. Paid plans exist in the data model (Starter, Growth,
  Enterprise) but nothing can be bought yet.
- Signed-out visitors see every supplier field except contact details.
- A register's current page is the truth for that register's own fields and shows without review.
- EPB is a government register: its evidence and HS codes show whenever EPB has them. EPB alone
  never creates a supplier.
- BGMEA registration numbers show only when backed by a BGMEA record.
- Workers means production workers: male plus female, never the sum of BGMEA's three figures.
- Product counts leave out sanctioned suppliers, so each count equals the search it opens.
- Customs shipment data is kept for one year from the day it was fetched, as agreed with Volza.
- An internal score orders search results. It is a sorting aid, never shown, never described.
