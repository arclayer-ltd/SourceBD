// The supplier claim's verification email (Spec S1, journaled from 0129 on). The link carries the one-time
// token; it is the only place the token leaves the database. Sent on claim_initiate and on an admin's resend.

import * as React from "react";
import { Button, Text } from "@react-email/components";

import { EmailLayout, emailStyles } from "./_layout";

export type ClaimVerifyData = {
  /** `${origin}/supplier/claim/verify?token=<token>`. */
  link: string;
  companyName: string;
  proofEmail: string;
  /** True when the proof email is at the company's own website domain and no other company uses it (claim_initiate, 0164), so the click itself approves the claim. */
  autoApprove: boolean;
};

export const claimVerifySubject = (d: ClaimVerifyData) => `Confirm ownership of ${d.companyName} on SourceBD`;

export function ClaimVerify({ data }: { data: ClaimVerifyData }) {
  return (
    <EmailLayout preview={`Confirm you control ${data.proofEmail} to claim ${data.companyName}.`} heading={`Claim ${data.companyName}`}>
      <Text style={emailStyles.paragraph}>
        You asked to claim <strong>{data.companyName}</strong> on SourceBD. To finish, confirm you control{" "}
        <strong>{data.proofEmail}</strong> by clicking the button below. The link works for 24 hours.
      </Text>
      <Button href={data.link} style={emailStyles.button}>
        Confirm this email
      </Button>
      <Text style={emailStyles.paragraph}>
        {data.autoApprove
          ? "Because this email is at the company's own web domain, the claim is activated as soon as you click."
          : "After you confirm, someone at SourceBD checks the claim. Its status shows on your claims page in SourceBD."}
      </Text>
      <Text style={emailStyles.muted}>If you did not ask for this, ignore this email and nothing changes.</Text>
    </EmailLayout>
  );
}

export default ClaimVerify;
