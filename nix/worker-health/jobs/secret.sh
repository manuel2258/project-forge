#!/bin/sh
# A job given a secret: what the loader put in its environment, and where the loader read it.
printf 'secret: %s\n' "${FORGE_HEALTH_SECRET-<unset>}"
printf 'credentials: %s\n' "${CREDENTIALS_DIRECTORY-<unset>}"
