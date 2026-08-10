"""Print the build id of the Valheim dedicated server's public branch.

Iron Gate publishes server updates to Steam app 896660. The build id changes on
every release, so it is what decides whether a nightly rebuild has anything to do.
Logs in anonymously; app 896660 needs no credentials.
"""

import sys

from steam.client import SteamClient

VALHEIM_DEDICATED_SERVER_APP_ID = 896660


def main() -> int:
    client = SteamClient()
    result = client.anonymous_login()
    if result != 1:  # EResult.OK
        print(f"anonymous Steam login failed: {result}", file=sys.stderr)
        return 1

    try:
        info = client.get_product_info(apps=[VALHEIM_DEDICATED_SERVER_APP_ID])
        app = info["apps"][VALHEIM_DEDICATED_SERVER_APP_ID]
        print(app["depots"]["branches"]["public"]["buildid"])
    finally:
        client.logout()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
