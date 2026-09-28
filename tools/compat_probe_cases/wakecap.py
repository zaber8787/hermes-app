"""WAKECAP-FIX: hot-swap must re-point the live router at the new handlers.

aiohttp binds each route row's handler OBJECT at connect() and freezes the
router at setup(); a plugin loaded afterwards never reaches those bindings
through class attributes alone (the real-machine capabilities bug: features.
auto_wake absent after control-socket reload, green from-scratch e2e). This
family replays that scenario offline: an app is constructed exactly like a
BOOT that predates compat's route edits (core handlers unwrapped to their
boot originals, compat-appended rows absent, catch-all ingress registered),
frozen by a real runner, and then the plugin's registered platform-handler
factory is invoked the same way the gateway's plugin-loaded rewire invokes
it — while the same site keeps serving. The router must end up resolving
every compat route row to the CURRENT class wrapper, with no restart.
"""
from __future__ import annotations
import inspect

from .offline import AUTH


def _sync_factories():
    from hermes_cli.plugins import get_plugin_manager
    return [f for f, plugin in get_plugin_manager().get_platform_handler_factories("api_server")
            if plugin == "hermes-app-compat"
            and getattr(f, "__qualname__", "").startswith("_route_sync_factory")]


def _boot_table(adapter):
    """The table a BOOT predating compat would have registered: the core
    route-table function (wrapper chain unwrapped) with every handler
    unwrapped to its boot original; compat-appended rows are absent by
    construction because the core function never returns them."""
    core_table = inspect.unwrap(type(adapter)._http_route_table)
    return [(method, path, inspect.unwrap(getattr(handler, "__func__", handler)))
            for method, path, handler in core_table(adapter)]


def _resolve(router):
    live = {}
    for resource in router.resources():
        for route in resource:
            method = getattr(route, "method", None) or "*"  # CatchAll routes
            live[(method, resource.canonical)] = \
                getattr(getattr(route, "_handler", None), "__func__",
                        getattr(route, "_handler", None))
    return live


async def case_wakecap(args, server, check):
    from aiohttp import ClientSession, ClientTimeout, web
    from gateway.platforms import api_server as api
    import importlib
    cls = api.APIServerAdapter
    state = getattr(api, "_hermes_app_compat_state_v1")
    compat = importlib.import_module("hermes_plugins.hermes_app_compat.compat")

    factories = _sync_factories()
    check(len(factories) >= 1, "route-sync factory registered on platform api_server")
    check(state["manifest"].get("wake", {}).get("route_sync") == "registered",
          "manifest records the route_sync registration")

    async with server() as (adapter, client):
        # Fresh boot (connect AFTER install) already serves the advertisement.
        async with client.get("/v1/capabilities", headers=AUTH) as r:
            caps = await r.json()
        check((caps.get("features") or {}).get("auto_wake", {}).get("enabled") is True,
              "fresh-boot capabilities advertise auto_wake")

        # ---- boot emulation, then the rewire, ONE live site throughout ----
        boot = web.Application()
        for method, path, func in _boot_table(adapter):
            bound = func.__get__(adapter, cls)
            boot.router.add_route(method, path, bound)
            boot.router.add_route(method, f"/p/{{profile}}{path}", bound)
        boot.router.add_route("*", "/p/{profile}/{tail:.*}", adapter._handle_profile_ingress)
        runner = web.AppRunner(boot)
        await runner.setup()  # freezes the router, exactly like a real boot
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        base_url = f"http://127.0.0.1:{runner.addresses[0][1]}"
        try:
            pre = _resolve(boot.router)
            check(getattr(pre[("GET", "/v1/capabilities")], "__hermes_app_compat__", None) is None,
                  "emulated boot binds the unwrapped boot capabilities handler")
            async with ClientSession(base_url=base_url, timeout=ClientTimeout(total=30)) as late:
                async with late.get("/v1/capabilities", headers=AUTH) as r:
                    broke = await r.json()
                check("auto_wake" not in (broke.get("features") or {}),
                      "boot-era binding hides the advertisement (bug reproduced offline)")
                async with late.get("/api/sessions/probe-sid/auto-wake/receipt",
                                    headers=AUTH, params={"batch_id": "ghost"}) as r:
                    body = await r.read()
                check(r.status == 404 and b"session_not_found" not in body
                      and b"wake" not in body.lower(),
                      "added wake routes 404 unhandled before the sync")

                # ---- install-path live scan (reload with a predating boot) --
                real_app, adapter._app = adapter._app, boot
                try:
                    compat._sync_live_adapters()
                finally:
                    adapter._app = real_app
                async with late.get("/v1/capabilities", headers=AUTH) as r:
                    scanned = await r.json()
                check((scanned.get("features") or {}).get("auto_wake", {}).get("enabled") is True,
                      "the install-time live scan repairs a predating boot without restart")

                # the plugin-loaded rewire invokes the factory on the FROZEN,
                # SERVING router — same path as the control-socket reload
                factories[-1](boot, adapter)

                async with late.get("/v1/capabilities", headers=AUTH) as r:
                    fixed = await r.json()
                check((fixed.get("features") or {}).get("auto_wake", {}).get("enabled") is True,
                      "same live process serves the advertisement after the sync")
                async with late.get("/api/sessions/probe-sid/auto-wake/receipt",
                                    headers=AUTH, params={"batch_id": "ghost"}) as r:
                    routed = await r.json()
                check(r.status == 404 and (routed.get("error") or {}).get("code")
                      == "session_not_found",
                      "added wake GET route now executes the wake handler")

            post = _resolve(boot.router)
            want = {}
            for method, path, handler in adapter._http_route_table():
                func = getattr(handler, "__func__", handler)
                for variant in (path, f"/p/{{profile}}{path}"):
                    want[(method, variant)] = func
            stale = sorted(f"{m} {v}" for (m, v), f in want.items()
                           if getattr(f, "__hermes_app_compat__", None) is not None
                           and post.get((m, v)) is not f)
            check(not stale, f"every compat route row resolves to the current handler ({stale[:4]})")
            check(post[("GET", "/v1/capabilities")] is cls._handle_capabilities,
                  "capabilities route runs the current wrapper head")
            check(post[("*", "/p/{profile}/{tail}")]
                  is pre[("*", "/p/{profile}/{tail}")]
                  and getattr(post[("*", "/p/{profile}/{tail}")],
                              "__hermes_app_compat__", None) is None,
                  "profile ingress catch-all untouched by the sync")
            patch_key = ("PATCH", "/api/sessions/{session_id}")
            check(post[patch_key] is pre[patch_key],
                  "untouched core rows keep their boot handler byte-identically")

            # idempotent: a second rewire changes nothing and breaks nothing
            factories[-1](boot, adapter)
            check(_resolve(boot.router) == post, "route sync is idempotent")
            async with ClientSession(base_url=base_url, timeout=ClientTimeout(total=30)) as late:
                async with late.get("/v1/capabilities", headers=AUTH) as r:
                    again = await r.json()
                check((again.get("features") or {}).get("auto_wake", {}).get("enabled") is True,
                      "advertisement survives repeated rewires")
        finally:
            await runner.cleanup()

    return None
