"""Test helper: configure the first guest the way server startup does (.env GUEST_* -> guestcfg.load_guests), for tests that need one guest."""
import os

from api import guestcfg, profile


def guests_for(admin_key, guest_key, session="", tag=None):
    env = {"GUEST_KEY": guest_key, "GUEST_SESSION": session, "GUEST_NAME": os.environ.get("GUEST_NAME", "")}
    if tag is not None:
        env["GUEST_TAG"] = tag
    return guestcfg.load_guests(admin_key, env, profile.guest_name_of)
