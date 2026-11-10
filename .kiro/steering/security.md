
## GitHub App tokens
- Mint with actions/create-github-app-token@v3 in the job that uses the token, just before use.
- Always set owner: greeterhq and exactly one repository in `repositories:`.
- Pass the token as GH_TOKEN via `env:`; never interpolate it into `run:`.
- Dispatch jobs declare `permissions: {}`.
