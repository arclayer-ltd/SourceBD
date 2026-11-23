# Sensitive work

This repository can be read by anyone. Issues, pull requests, commit messages and comments are
public the moment they are written.

So a fault that would let someone get in, read what they should not, or damage the data is never
described in public before its fix is live:

- Do not open a public issue that explains how to exploit it.
- Use a title and description that say what is being hardened, not how it breaks. "Tighten how a
  new account's role is set" is enough for a reviewer who can read the diff.
- Keep the working detail in a private report to the founder, or in a draft security advisory on
  GitHub, which stays private on a public repository.
- Once the fix is live and seen working, the issue may say plainly what it was.

The same care applies to anything personal or commercial: no real person's contact details, no
buyer's name, no key, password or token, and no production data beyond what the site already
shows the public, in any issue, pull request, test or file.
