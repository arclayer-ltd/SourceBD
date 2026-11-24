// The page the claim email links to, with `?token=…`. It spends the token with the visitor's own
// session (the middleware has already sent anyone signed out to sign in and back here) and says what
// happened. It used to POST to /api/v1/claims from the server, without the visitor's cookies, so the
// middleware answered "not authenticated" to every click (issue 643).

import { ClaimStatusChip, ClaimSteps } from "@/components/claim/parts";
import { ButtonLink, ErrorPanel } from "@/components/kit";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type Verified = {
  ok?: boolean;
  outcome?: "approved" | "pending_admin" | "invalid" | "expired" | "not_pending" | "supplier_taken";
  claim_id?: string;
  status?: string;
};

/** What each refusal from claim_verify_email means to the person holding the link. */
type Refusal = { title: string; detail: string };

const INVALID: Refusal = {
  title: "This link does not work",
  detail: "It may have been copied only in part, or replaced by a newer link. Open the latest claim email, or start the claim again.",
};

const REFUSED: Record<string, Refusal> = {
  invalid: INVALID,
  expired: {
    title: "This link has expired",
    detail: "Claim links work for 24 hours. Start the claim again and a new link is emailed.",
  },
  not_pending: {
    title: "This link has already been used",
    detail: "The claim has moved on since this email was sent. Its status is on your claims page.",
  },
  supplier_taken: {
    title: "This company has already been claimed",
    detail: "Someone else finished claiming it before you clicked. If that is wrong, tell us through the contact page.",
  },
};

export default async function ClaimVerifyPage({
  searchParams,
}: {
  searchParams: Promise<{ token?: string }>;
}) {
  const token = (await searchParams).token?.trim();
  if (!token) {
    return (
      <ErrorCard
        title="Missing token"
        detail="The verification link is malformed. Try opening it from your email again."
      />
    );
  }

  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("claim_verify_email", { p_token: token });
  if (error) {
    return <ErrorCard title="Could not verify" detail="Something went wrong on our side. Try the link again in a minute." />;
  }

  const result = (data ?? {}) as Verified;
  if (!result.ok) {
    const refused = REFUSED[result.outcome ?? ""] ?? INVALID;
    return <ErrorCard title={refused.title} detail={refused.detail} claimId={result.claim_id} />;
  }

  const approved = result.outcome === "approved";
  return (
    <div className="mx-auto flex w-full max-w-[560px] flex-col gap-6">
      <ClaimSteps current={2} />
      <header className="flex flex-col gap-1">
        <h1 className="text-2xl font-semibold tracking-tight text-ink">Email verified</h1>
      </header>
      <div>
        <ClaimStatusChip status={approved ? "approved" : "email_verified"}>
          {approved ? "Claim approved" : "Awaiting admin review"}
        </ClaimStatusChip>
      </div>
      <p className="text-md text-ink-2">
        {approved
          ? "Your email is at this company's own web domain, so the claim is approved. You now manage this company on SourceBD."
          : "Thanks. Someone at SourceBD now checks that this email belongs to the company. The decision shows on your claim's page."}
      </p>
      <div>
        <ButtonLink kind="primary" href={result.claim_id ? `/supplier/claim/${result.claim_id}` : "/supplier/claim"}>
          {result.claim_id ? "View claim" : "Back to claims"}
        </ButtonLink>
      </div>
    </div>
  );
}

function ErrorCard({ title, detail, claimId }: { title: string; detail: string; claimId?: string }) {
  const href = claimId ? `/supplier/claim/${claimId}` : "/supplier/claim";
  return (
    <div className="mx-auto flex w-full max-w-[560px] flex-col gap-6">
      <header className="flex flex-col gap-1">
        <h1 className="text-2xl font-semibold tracking-tight text-ink">{title}</h1>
      </header>
      <ErrorPanel title={detail} retry={<ButtonLink href={href}>{claimId ? "View claim" : "Back to claims"}</ButtonLink>} />
    </div>
  );
}
