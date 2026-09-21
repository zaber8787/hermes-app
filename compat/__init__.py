"""Hermes user plugin; importing this package does not install patches."""
import logging


def register(ctx):
    try:
        from .compat import install
        install(ctx)
    except Exception as exc:
        # Import failures must not interrupt discovery of unrelated plugins.
        logging.getLogger(__name__).warning(
            "hermes-app-compat manifest: all skipped_incompatible (%s)", type(exc).__name__)
