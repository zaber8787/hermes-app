"""Pin ``compat`` to the package before any test shadows it.

Some legacy tests prepend ``compat/`` itself to ``sys.path`` so they can
``import notification_events`` top-level. When such a file is collected first,
a later ``import compat`` resolves to the ``compat/compat.py`` *file* instead
of the ``compat/`` package, and ``from compat import <module>`` blows up for
every package-style test in the run. Importing the package here (conftest runs
before test-module import) caches it in ``sys.modules`` so the shadowing file
can never win.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import compat  # noqa: E402  (imported for its sys.modules binding)
