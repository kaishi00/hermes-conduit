"""Shared helpers for the CI tooling regression tests (stdlib only)."""

import importlib.util
import os

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_module(name, filename):
    """Load a script module whose file name is not importable (hyphens)."""
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(SCRIPTS_DIR, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_swift(path, class_name, superclass="XCTestCase", body="func testSomethingWorks() {}"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "import XCTest\n\nfinal class {0}: {1} {{\n    {2}\n}}\n".format(
            class_name, superclass, body),
        encoding="utf-8",
    )


def make_repo(root, unit_classes=(), ui_classes=(), extra_files=None):
    """Create a synthetic repo tree with ConduitTests/ and ConduitUITests/."""
    root.mkdir(parents=True, exist_ok=True)
    # Both target directories always exist: the planner treats a missing
    # target directory as a hard error (broken checkout), and fixtures should
    # model a valid tree unless they test exactly that error.
    (root / "ConduitTests").mkdir(exist_ok=True)
    (root / "ConduitUITests").mkdir(exist_ok=True)
    for name in unit_classes:
        write_swift(root / "ConduitTests" / (name + ".swift"), name)
    for name in ui_classes:
        write_swift(root / "ConduitUITests" / (name + ".swift"), name)
    for relpath, content in (extra_files or {}).items():
        target = root / relpath
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    return root


def default_cfg(**overrides):
    cfg = {
        "default_estimate_s": 20.0,
        "min_lanes": 4,
        "max_lanes": 8,
        "target_budget_s": 240.0,
        "lane_timeout_min_s": 300,
        "timeout_multiplier": 2.5,
        "ui_timeout_min_s": 420,
        "job_timeout_margin_s": 600,
    }
    cfg.update(overrides)
    return cfg
