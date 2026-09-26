# Security

**The API has no authentication.** Anyone who can reach it can search, add torrents, and
stream. Run Cineseed on a private network or VPN, or put your own auth (Caddy
`basic_auth`, an OAuth/forward-auth proxy) in front of it.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting (**Security → Report a vulnerability** on
this repo). Please don't open a public issue. Only the latest release is supported.
