## Environment/secret loading: reads `$NAME` from OS env, falling back to a
## local `.env` file in CWD.

import std/[os, strutils]

proc stripEnvQuotes*(value: string): string =
  result = value.strip()
  if result.len >= 2:
    if (result[0] == '"' and result[^1] == '"') or (result[0] == '\'' and result[^1] == '\''):
      result = result[1 .. ^2]

proc loadDotEnvValue*(name: string): string =
  let envPath = getCurrentDir() / ".env"
  if not fileExists(envPath):
    return ""

  for line in readFile(envPath).splitLines():
    let trimmed = line.strip()
    if trimmed == "" or trimmed.startsWith("#"):
      continue
    let eq = trimmed.find('=')
    if eq <= 0:
      continue
    let key = trimmed[0 ..< eq].strip()
    if key == name:
      return stripEnvQuotes(trimmed[eq + 1 .. ^1])
  ""

proc getSecret*(name: string): string =
  result = getEnv(name)
  if result == "":
    result = loadDotEnvValue(name)
